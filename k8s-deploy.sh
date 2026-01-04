#!/bin/bash
# Interactive script to clone a GitHub repo, build Docker images,
# and generate Kubernetes manifests INSIDE the cloned repo

set -euo pipefail  # Better error handling

# === Input prompts ===
read -p "Enter GitHub repo URL (e.g., https://github.com/user/repo): " repo_url
read -p "Enter GitHub token (if private repo; leave blank for public): " -s token
echo
read -p "Enter branch (default: main): " branch
branch=${branch:-main}
read -p "Enter PVC size (e.g., 10Gi, default 10Gi): " pvc_size
pvc_size=${pvc_size:-10Gi}
read -p "Use custom image tag? (y/n, default n): " use_custom
use_custom=${use_custom:-n}

if [[ "$use_custom" =~ ^[Yy]$ ]]; then
    read -p "Enter custom tag: " tag
else
    tag=$(shuf -i 10000-99999 -n 1)
fi

# === Extract repo details ===
repo_name=$(basename "$repo_url" .git)
repo_clean=$(echo "$repo_url" | sed 's|^https://||')

# === Clone the repository ===
if [[ -n "$token" ]]; then
    clone_url="https://$token@$repo_clean"
else
    clone_url="https://$repo_clean"
fi

echo "Cloning $repo_url (branch: $branch)..."
git clone "$clone_url" -b "$branch" "$repo_name"
cd "$repo_name" || { echo "Failed to enter repo directory"; exit 1; }

# === Find all Dockerfiles ===
dockerfiles=$(find . -name Dockerfile -type f)

if [[ -z "$dockerfiles" ]]; then
    echo "No Dockerfiles found in the repository. Exiting."
    exit 1
fi

echo "Found Dockerfiles:"
printf "  %s\n" $dockerfiles

# === Build Docker images ===
echo "Building Docker images with tag :$tag"
for dockerfile in $dockerfiles; do
    dir=$(dirname "$dockerfile")
    subdir=$(basename "$dir")

    if [[ "$dir" == "." ]]; then
        app_name="$repo_name"
    else
        app_name="$repo_name-$subdir"
    fi

    echo "Building $app_name:$tag from $dockerfile"
    docker build -t "$app_name:$tag" -f "$dockerfile" "$dir"
done

# === Load images to kind cluster ===
echo "Loading Docker images to kind cluster 'staging-cluster'"
for dockerfile in $dockerfiles; do
    dir=$(dirname "$dockerfile")
    subdir=$(basename "$dir")

    if [[ "$dir" == "." ]]; then
        app_name="$repo_name"
    else
        app_name="$repo_name-$subdir"
    fi

    echo "Loading $app_name:$tag to kind cluster"
    kind load docker-image "$app_name:$tag" --name staging-cluster
done

# === Create k8s-manifests directory INSIDE the cloned repo ===
mkdir -p k8s-manifests

# === Generate Namespace ===
cat > k8s-manifests/namespace.yaml <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $repo_name
EOF

# === Generate Deployment + Service for each app ===
for dockerfile in $dockerfiles; do
    dir=$(dirname "$dockerfile")
    subdir=$(basename "$dir")

    if [[ "$dir" == "." ]]; then
        app_name="$repo_name"
    else
        app_name="$repo_name-$subdir"
    fi

    # Extract exposed port (default to 80)
    port=$(grep -i '^EXPOSE' "$dockerfile" | awk '{print $2}' | head -1 || echo "")
    port=${port:-80}

    # Deployment
    cat > "k8s-manifests/${app_name}-deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $app_name
  namespace: $repo_name
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $app_name
  template:
    metadata:
      labels:
        app: $app_name
    spec:
      containers:
      - name: $app_name
        image: $app_name:$tag
        ports:
        - containerPort: $port
EOF

    # Service
    cat > "k8s-manifests/${app_name}-service.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${app_name}-service
  namespace: $repo_name
spec:
  selector:
    app: $app_name
  ports:
  - port: $port
    targetPort: $port
  type: ClusterIP
EOF
done

# === Optional: Handle .env files (ConfigMap / Secret) and Database if database details found ===
env_files=$(find . -name ".env" -type f)
if [[ -n "$env_files" ]] && [[ -f init.sql ]]; then
    db_type=$(grep -h "^DB_TYPE=" $env_files | cut -d'=' -f2 | xargs | head -1)

    if [[ -n "$db_type" ]]; then
        config_data=""
        secret_data=""

        for file in $env_files; do
            while IFS='=' read -r key value || [[ -n "$key" ]]; do
                # Skip comments and empty lines
                [[ "$key" =~ ^#.*$ ]] && continue
                [[ -z "$key" ]] && continue

                # Trim whitespace
                key=$(echo "$key" | xargs)
                value=$(echo "$value" | xargs)

                # Override DATABASE_HOST to the database service name
                if [[ "$key" == "DATABASE_HOST" ]]; then
                    value="${repo_name}-database-service"
                fi

                # Classify as secret if key suggests sensitivity
                if [[ "$key" =~ ^(PASSWORD|SECRET|TOKEN|KEY|PASS|API_KEY|DB_PASSWORD|USER)$ ]]; then
                    secret_data="$secret_data  $key: $(echo -n "$value" | base64 -w0)\n"
                else
                    config_data="$config_data  $key: \"$value\"\n"
                fi
            done < "$file"
        done

        if [[ -n "$config_data" ]]; then
            cat > "k8s-manifests/${repo_name}-configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${repo_name}-config
  namespace: $repo_name
data:
$config_data
EOF
        fi

        if [[ -n "$secret_data" ]]; then
            cat > "k8s-manifests/${repo_name}-secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${repo_name}-secret
  namespace: $repo_name
type: Opaque
data:
$secret_data
EOF
        fi

        case "$db_type" in
            mysql|MySQL)
                db_image="mysql:8.0"
                db_port=3306
                mount_path="/var/lib/mysql"
                ;;
            postgres|postgresql|PostgreSQL)
                db_image="postgres:13"
                db_port=5432
                mount_path="/var/lib/postgresql/data"
                ;;
            *)
                echo "Unsupported DB_TYPE: $db_type (supported: mysql, postgres)"
                exit 1
                ;;
        esac

        # PVC
        cat > "k8s-manifests/${repo_name}-database-pvc.yaml" <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${repo_name}-database-pvc
  namespace: $repo_name
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: $pvc_size
EOF

        # Database Deployment
        cat > "k8s-manifests/${repo_name}-database-deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${repo_name}-database
  namespace: $repo_name
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${repo_name}-database
  template:
    metadata:
      labels:
        app: ${repo_name}-database
    spec:
      containers:
      - name: database
        image: $db_image
        ports:
        - containerPort: $db_port
        volumeMounts:
        - name: database-storage
          mountPath: $mount_path
        envFrom:
        - configMapRef:
            name: ${repo_name}-config
        - secretRef:
            name: ${repo_name}-secret
      volumes:
      - name: database-storage
        persistentVolumeClaim:
          claimName: ${repo_name}-database-pvc
EOF

        # Database Service
        cat > "k8s-manifests/${repo_name}-database-service.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${repo_name}-database-service
  namespace: $repo_name
spec:
  selector:
    app: ${repo_name}-database
  ports:
  - port: $db_port
    targetPort: $db_port
EOF
    fi
fi

# === Final summary ===
echo ""
echo "=========================================="
echo "Success! Kubernetes manifests generated inside the repo at:"
echo "   $(pwd)/k8s-manifests/"
echo ""
echo "Docker images built (local only):"
for dockerfile in $dockerfiles; do
    dir=$(dirname "$dockerfile")
    subdir=$(basename "$dir")
    if [[ "$dir" == "." ]]; then
        app_name="$repo_name"
    else
        app_name="$repo_name-$subdir"
    fi
    echo "   - $app_name:$tag"
done
echo ""
echo "Next steps:"
echo "   1. (Optional) Commit and push the k8s-manifests/ folder to your repo"
echo "   2. Push images to a registry: docker push <registry>/<app_name>:$tag"
echo "   3. Update image names in manifests if using a remote registry"
echo "   4. Deploy: kubectl apply -f k8s-manifests/"
echo "=========================================="