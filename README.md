# StartupTech – MuchToDo Backend Deployment

Terraform and Docker setup for the [MuchToDo](https://github.com/Innocent9712/much-to-do/tree/feature/backend-only) Go backend on AWS.

- **Phase 1 – Terraform:** VPC, subnets, NAT, security groups, Bastion / Backend / MongoDB EC2 instances, and an Application Load Balancer.
- **Phase 2 – Docker:** multi-stage Dockerfile and a Docker Compose stack (backend + MongoDB), deployed to the backend EC2 instance and served through the ALB.

## Architecture

```
                        Internet
                           │
                  ┌────────▼────────┐
                  │  ALB  :80 (:443)│   public subnets (AZ a, AZ b)
                  └────────┬────────┘
   my IP ──SSH──► Bastion (EIP)      │ :8080  (ALB SG → Backend SG)
                     │ SSH           │
           ┌─────────▼───────────────▼──┐
           │ Backend EC2 (private, AZ a)│  docker compose:
           │   backend :8080 ── mongodb │    backend + mongo:8.0 (volume)
           └─────────────┬──────────────┘
                         │ :27017 (Backend SG → MongoDB SG)
           ┌─────────────▼──────────────┐
           │ MongoDB EC2 (private, AZ b)│  MongoDB 7.0, auth + replica set
           └────────────────────────────┘
   Private subnets reach the internet through a single NAT Gateway in public subnet A.
```

| Security group | Inbound | Source |
|---|---|---|
| `startuptech-alb-sg` | 80, 443 | `0.0.0.0/0` |
| `startuptech-bastion-sg` | 22 | your IP (`/32`) |
| `startuptech-backend-sg` | 8080 | ALB SG |
| | 22 | Bastion SG |
| `startuptech-mongodb-sg` | 27017 | Backend SG |
| | 22 | Bastion SG (admin only) |

The ALB's outbound rule only allows port 8080 to the backend SG.

## Repository layout

```
backend-deployment-assessment/
├── terraform/
│   ├── main.tf                    # all AWS resources
│   ├── variables.tf               # inputs with descriptions and defaults
│   ├── outputs.tf                 # VPC ID, ALB DNS, bastion IP, backend IP, ...
│   ├── terraform.tfvars.example   # copy to terraform.tfvars
│   ├── terraform.tfstate          # exported state (added after apply)
│   └── user_data/
│       ├── backend_setup.sh       # Docker, Docker Compose, Buildx, git, swap
│       └── mongodb_setup.sh       # MongoDB 7.0 with auth
├── Dockerfile                     # multi-stage Go build, non-root, HEALTHCHECK
├── docker-compose.yml             # backend + MongoDB
├── .dockerignore
├── .env.example                   # copy to .env for docker compose
├── evidence/                      # screenshots
└── README.md
```

## Prerequisites

| Tool | Version used | Check |
|---|---|---|
| AWS account + IAM user/role allowed to manage VPC, EC2, ELB | – | `aws sts get-caller-identity` |
| AWS CLI v2 | 2.x | `aws --version` |
| Terraform | ≥ 1.6 | `terraform version` |
| Docker Desktop / Engine with Compose v2 | 24+ | `docker compose version` |
| Git | any | `git --version` |
| An SSH key pair | ed25519 or RSA | `ls ~/.ssh/id_ed25519.pub` |

Create an SSH key if you don't have one:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -C "startuptech"
```

> Terraform only uploads the **public** key, so no private key ends up in state.

---

## Phase 1 – Provision infrastructure with Terraform

### 1. Configure credentials and variables

```bash
aws configure            # or: aws sso login / aws login
aws sts get-caller-identity

cd terraform
cp terraform.tfvars.example terraform.tfvars
curl -s https://checkip.amazonaws.com   # your public IP
```

Edit `terraform.tfvars`:

```hcl
aws_region      = "us-east-1"
my_ip           = "<your-ip>/32"     # remove this line to auto-detect it
public_key_path = "~/.ssh/id_ed25519.pub"
```

| Variable | Default | Description |
|---|---|---|
| `aws_region` | `us-east-1` | Region to deploy into |
| `bastion_instance_type` | `t3.micro` | Bastion instance type |
| `backend_instance_type` | `t3.micro` | Backend instance type |
| `mongodb_instance_type` | `t3.micro` | MongoDB instance type |
| `my_ip` | `null` (auto-detect) | CIDR allowed to SSH to the bastion |
| `public_key_path` | `~/.ssh/id_ed25519.pub` | Public key for the EC2 key pair |
| `project_name` | `startuptech` | Prefix for names and tags |
| `vpc_cidr` | `10.0.0.0/16` | VPC CIDR |
| `public_subnet_cidrs` | `10.0.1.0/24`, `10.0.2.0/24` | Public subnets |
| `private_subnet_cidrs` | `10.0.11.0/24`, `10.0.12.0/24` | Private subnets |

### 2. Init, plan, apply

```bash
terraform init                         # screenshot 1
terraform fmt -check && terraform validate
terraform plan -out=tfplan             # screenshot 2
terraform apply tfplan                 # screenshot 3 ("Apply complete! Resources: N added")
terraform output
```

Outputs:

| Output | Description |
|---|---|
| `vpc_id` | VPC ID |
| `alb_dns_name` | ALB DNS name |
| `bastion_public_ip` | Bastion Elastic IP |
| `backend_private_ip` | Backend private IP |
| `mongodb_private_ip` | MongoDB private IP |
| `ssh_to_backend` | Ready-made SSH command through the bastion |
| `app_url` | `http://<alb>/health` |

User data takes about 3–5 minutes after apply. Until the app is deployed (Phase 2), the target group shows the backend as **unhealthy**. That is expected.

### 3. Check in the AWS Console (screenshots 4–8)

- **VPC** → Your VPCs → `startuptech-vpc`, CIDR `10.0.0.0/16`
- **VPC** → Subnets → filter by the VPC: 2 public and 2 private subnets across 2 AZs
- **EC2** → Security Groups → the four `startuptech-*-sg` groups → *Inbound rules*
- **EC2** → Instances → `startuptech-bastion`, `startuptech-backend`, `startuptech-mongodb` all *Running*
- **EC2** → Load Balancers → `startuptech-alb` *Active*; Target Groups → `startuptech-backend-tg` → *Healthy* (after Phase 2)

---

## Phase 2 – Docker

### Design notes

- **Build context** is this repo's root. The app source is cloned into `./app` (git-ignored). `.dockerignore` excludes everything except `go.mod`, `go.sum`, `cmd/`, `internal/`, and `docs/`. Tests are excluded too.
- **Multi-stage:** `golang:1.25-alpine` compiles a static, stripped binary. The runtime image is `alpine:3.20` with only the binary and CA certificates (about 67 MB).
- **Non-root:** the app runs as `app` (uid 10001).
- **HEALTHCHECK** calls `GET /health` with busybox `wget`.
- **Config:** the app uses viper, which only reads env vars for keys it already knows. The image includes a `.env` template that lists every key with no secrets. Real values come from container environment variables.
- **MongoDB as a replica set:** deleting a user runs a MongoDB transaction, and transactions need a replica set. Compose runs `mongo:8.0` as a single-node replica set `rs0` with auth. The keyfile is generated inside the container at startup. The healthcheck starts the replica set and only reports healthy once the node is primary. The backend waits for that (`depends_on: condition: service_healthy`).
- **Persistence:** named volumes `mongo_data` and `mongo_config`.
- **Networking:** both services share the `muchtodo-net` bridge network. MongoDB publishes no host port.
- **Restart policy:** `unless-stopped` on both services.

### 1. Run locally

```bash
# from the repo root
git clone -b feature/backend-only https://github.com/Innocent9712/much-to-do.git app

cp .env.example .env
# set strong values:
sed -i.bak "s/^MONGO_ROOT_PASSWORD=.*/MONGO_ROOT_PASSWORD=$(openssl rand -hex 16)/" .env
sed -i.bak "s/^JWT_SECRET_KEY=.*/JWT_SECRET_KEY=$(openssl rand -hex 32)/" .env && rm .env.bak

docker build -t muchtodo-backend:latest .        # screenshot 9
docker compose up -d                             # screenshot 10
docker compose ps
curl -i http://localhost:8080/health             # screenshot 11 -> 200 {"cache":"disabled","database":"ok"}
```

Quick API smoke test:

```bash
curl -s -X POST localhost:8080/auth/register -H 'Content-Type: application/json' \
  -d '{"firstName":"Ada","lastName":"Lovelace","username":"ada","password":"secret123"}'
TOKEN=$(curl -s -X POST localhost:8080/auth/login -H 'Content-Type: application/json' \
  -d '{"username":"ada","password":"secret123"}' | sed -E 's/.*"token":"([^"]+)".*/\1/')
curl -s -X POST localhost:8080/todos/ -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{"title":"Ship it"}'
curl -s localhost:8080/todos/ -H "Authorization: Bearer $TOKEN"
```

Swagger UI: <http://localhost:8080/swagger/index.html>

### 2. Deploy to the backend EC2 instance

**SSH through the bastion** (screenshot 12). Load your key into the agent, then jump through the bastion:

```bash
cd terraform
BASTION=$(terraform output -raw bastion_public_ip)
BACKEND=$(terraform output -raw backend_private_ip)

ssh-add ~/.ssh/id_ed25519
ssh -A -J ec2-user@$BASTION ec2-user@$BACKEND
# or two hops:  ssh -A ec2-user@$BASTION   then   ssh ec2-user@$BACKEND
```

**On the backend server:**

```bash
# confirm user data finished
sudo tail -n 5 /var/log/backend_setup.log     # "backend setup complete"
docker --version && docker compose version

# get the deployment files and the application source
git clone https://github.com/<your-github-user>/backend-deployment-assessment.git
cd backend-deployment-assessment
git clone -b feature/backend-only https://github.com/Innocent9712/much-to-do.git app

# secrets
cp .env.example .env
sed -i "s/^MONGO_ROOT_PASSWORD=.*/MONGO_ROOT_PASSWORD=$(openssl rand -hex 16)/" .env
sed -i "s/^JWT_SECRET_KEY=.*/JWT_SECRET_KEY=$(openssl rand -hex 32)/" .env

docker compose up -d --build      # first build takes a few minutes on t3.micro
docker compose ps                 # screenshot 13: both containers Up (healthy)
curl -s localhost:8080/health
```

**Check through the ALB** (screenshot 14), from your laptop:

```bash
ALB=$(terraform -chdir=terraform output -raw alb_dns_name)
curl -i http://$ALB/health
curl -i http://$ALB/
```

The target group turns **healthy** after two passing checks (about 1 minute).

### Optional: use the dedicated MongoDB EC2 instance

By default the backend uses the MongoDB container. To use the MongoDB EC2 instance instead:

```bash
# from your laptop: read the generated admin password
ssh -J ec2-user@$BASTION ec2-user@$(terraform -chdir=terraform output -raw mongodb_private_ip) \
  'sudo cat /root/mongodb-admin-password'
```

Add this line to `.env` on the backend server, then run `docker compose up -d backend`:

```
MONGO_URI=mongodb://admin:<password>@<mongodb-private-ip>:27017/?authSource=admin&replicaSet=rs0
```

---

## Terraform state and secrets

- `terraform.tfvars` is git-ignored. Only `terraform.tfvars.example` is committed.
- State contains **no secrets**:
  - Only the SSH **public** key is uploaded.
  - The MongoDB admin password is generated **on the instance** by user data, so Terraform never sees it.
  - App secrets (`JWT_SECRET_KEY`, `MONGO_ROOT_PASSWORD`) live only in `.env` on the server, which is git-ignored.
- The local backend writes state to `terraform/terraform.tfstate`. To check it and commit it after `apply`:

  ```bash
  cd terraform
  grep -iE '"(password|secret|private_key)' terraform.tfstate || echo "no secrets found"
  git add terraform.tfstate
  ```

  Commit the state **after** `apply`, not after `destroy`, or the file will be empty.

## Teardown / cleanup

```bash
# 1. On the backend server (optional, the instance is destroyed anyway)
docker compose down -v

# 2. Locally
docker compose down -v                    # stop containers and delete volumes
docker image rm muchtodo-backend:latest

# 3. AWS infrastructure
cd terraform
terraform destroy                         # type "yes"
```

`terraform destroy` removes the NAT Gateway and both Elastic IPs. These cost money even when idle, so don't skip this step. Afterwards, check in the console that no `startuptech-*` resources remain.

## Troubleshooting

| Symptom | Check |
|---|---|
| SSH to bastion times out | Your IP changed. Update `my_ip` and run `terraform apply` again. |
| `docker: command not found` on backend | User data still running: `sudo tail -f /var/log/backend_setup.log` |
| `permission denied ... docker.sock` | Log out and back in so the `docker` group applies, or use `sudo`. |
| Target group unhealthy | `docker compose ps`; `curl localhost:8080/health` on the backend. A 503 means MongoDB is not reachable. |
| Build killed on t3.micro | User data adds 2 GB swap. Check with `free -m`. |
| ALB 502/504 | Backend container not listening on 8080 yet. Check `docker compose logs backend`. |

HTTPS (443) is open on the ALB security group as required, but there is no 443 listener because that needs an ACM certificate for a domain you own. Add an `aws_lb_listener` on 443 with `certificate_arn` once you have one.
# backend-deployment-assessment
