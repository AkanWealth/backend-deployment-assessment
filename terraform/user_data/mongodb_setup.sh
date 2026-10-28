#!/bin/bash
# MongoDB server bootstrap (Amazon Linux 2): MongoDB 7.0 as a single-node
# replica set (the app uses transactions) with authentication enabled.
#
# The admin password is generated here, on the instance, so it never appears
# in Terraform state. Read it with:
#   sudo cat /root/mongodb-admin-password
#
# Log: /var/log/mongodb_setup.log
set -euxo pipefail
exec > >(tee -a /var/log/mongodb_setup.log) 2>&1

MONGO_VERSION="7.0"

cat > /etc/yum.repos.d/mongodb-org-${MONGO_VERSION}.repo <<EOF
[mongodb-org-${MONGO_VERSION}]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/amazon/2/mongodb-org/${MONGO_VERSION}/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://pgp.mongodb.com/server-${MONGO_VERSION}.asc
EOF

yum update -y
yum install -y mongodb-org openssl

# Keyfile for replica-set internal auth (also turns on client auth).
install -d -o mongod -g mongod -m 700 /etc/mongodb
openssl rand -base64 756 > /etc/mongodb/keyfile
chown mongod:mongod /etc/mongodb/keyfile
chmod 400 /etc/mongodb/keyfile

cat > /etc/mongod.conf <<'EOF'
storage:
  dbPath: /var/lib/mongo
systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log
processManagement:
  timeZoneInfo: /usr/share/zoneinfo
net:
  port: 27017
  # Listen on all interfaces; the security group only allows the backend.
  bindIp: 0.0.0.0
security:
  authorization: enabled
  keyFile: /etc/mongodb/keyfile
replication:
  replSetName: rs0
EOF

systemctl enable mongod
systemctl restart mongod

# Wait for mongod to accept connections.
for i in $(seq 1 30); do
  mongosh --quiet --eval 'db.runCommand({ ping: 1 })' && break
  sleep 2
done

# Private IP (IMDSv2) so the replica-set member is reachable from the backend.
TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)

# First boot only: initiate replica set and create the admin user
# (allowed by the localhost exception before any user exists).
if [ ! -f /root/mongodb-admin-password ]; then
  ADMIN_PASSWORD=$(openssl rand -hex 24)

  mongosh --quiet --eval "rs.initiate({_id: 'rs0', members: [{_id: 0, host: '${PRIVATE_IP}:27017'}]})"

  for i in $(seq 1 30); do
    mongosh --quiet --eval 'quit(db.hello().isWritablePrimary ? 0 : 1)' && break
    sleep 2
  done

  mongosh --quiet admin --eval "db.createUser({user: 'admin', pwd: '${ADMIN_PASSWORD}', roles: [{role: 'root', db: 'admin'}]})"

  umask 077
  echo "$ADMIN_PASSWORD" > /root/mongodb-admin-password
fi

echo "mongodb setup complete"
