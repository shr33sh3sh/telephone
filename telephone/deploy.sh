#!/bin/bash
# File: deploy.sh

echo "Creating namespace..."
kubectl apply -f k8s/namespace.yaml

echo "Creating configmap and secrets..."
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/secrets.yaml

echo "Deploying PostgreSQL..."
kubectl apply -f k8s/postgres/persistent-volume.yaml
kubectl apply -f k8s/postgres/deployment.yaml
kubectl apply -f k8s/postgres/service.yaml

echo "Waiting for PostgreSQL to be ready..."
kubectl wait --namespace phone-directory --for=condition=ready pod --selector=app=postgres --timeout=120s

echo "Building Docker images..."
# Build your images first
docker build -t phone-directory-web:latest ./web
docker build -t phone-directory-cli:latest ./cli

kind load docker-image phone-directory-web:latest --name staging-cluster
kind load docker-image phone-directory-cli:latest --name staging-cluster
# If you have a registry, push them:
# docker push your-registry/phone-directory-web:latest
# docker push your-registry/phone-directory-cli:latest

echo "Deploying Web Application..."
kubectl apply -f k8s/web/deployment.yaml
kubectl apply -f k8s/web/service.yaml

echo "Deployment complete!"
echo ""
echo "Access your application:"
echo "1. NodePort: http://<any-node-ip>:30080"
echo "2. Port-forward: kubectl port-forward -n phone-directory svc/web-service 8080:80"
echo ""
echo "Check status:"
echo "kubectl get all -n phone-directory"