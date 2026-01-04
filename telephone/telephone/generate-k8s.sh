#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:-.}"
TAG="${2:-latest}"
PARENT_NAME="$(basename "$(realpath "$ROOT_DIR")")"
K8S_OUT_DIR="$ROOT_DIR/k8s-manifests"

mkdir -p "$K8S_OUT_DIR"

echo "📦 Project: $PARENT_NAME"
echo

############################################
# Helper: trim whitespace
############################################
trim() {
  awk '{$1=$1};1'
}

############################################
# 🎯 NAMESPACE SECTION — Create namespace
############################################
# Make namespace DNS-1123 safe
NAMESPACE="$(echo "$PARENT_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"
NAMESPACE="${NAMESPACE##-}"
NAMESPACE="${NAMESPACE%%-}"
[[ -z "$NAMESPACE" ]] && NAMESPACE="app-namespace"

NS_FILE="$K8S_OUT_DIR/namespace.yaml"

cat > "$NS_FILE" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NAMESPACE
EOF

echo "📝 Created namespace: $NAMESPACE"
echo

############################################
# 🔍 Scan for .env files FIRST
############################################
echo "🔍 Scanning for .env files..."
mapfile -t ENV_FILES < <(find "$ROOT_DIR" -type f -iname ".env*" ! -iname "*.example")

CM_FILE="$K8S_OUT_DIR/config.yaml"
SEC_FILE="$K8S_OUT_DIR/secret.yaml"

# Initialize empty associative arrays for tracking variables
declare -A CONFIG_VARS
declare -A SECRET_VARS

# Parse .env files
if [[ ${#ENV_FILES[@]} -gt 0 ]]; then
  for ENV_FILE in "${ENV_FILES[@]}"; do
    echo "  Processing: $ENV_FILE"
    while IFS='=' read -r KEY VALUE || [[ -n "$KEY" ]]; do
      KEY="$(echo "$KEY" | trim)"
      [[ -z "$KEY" ]] && continue
      [[ "$KEY" =~ ^# ]] && continue

      VALUE="${VALUE:-}"
      VALUE="$(echo "$VALUE" | trim)"
      # Remove quotes from value
      VALUE="${VALUE#\"}"
      VALUE="${VALUE%\"}"
      VALUE="${VALUE#\'}"
      VALUE="${VALUE%\'}"

      if [[ "$KEY" =~ (PASS|PASSWORD|TOKEN|SECRET|KEY|USER) ]]; then
        SECRET_VARS["$KEY"]="$VALUE"
      else
        CONFIG_VARS["$KEY"]="$VALUE"
      fi
    done < "$ENV_FILE"
  done
fi

############################################
# 🔍 Scan for database init SQL files...
############################################
echo "🔍 Scanning for database init SQL files..."

mapfile -t SQL_FILES < <(find "$ROOT_DIR" -maxdepth 2 -type f \( -iname "init.sql" -o -iname "*.sql" \))

if [[ ${#SQL_FILES[@]} -eq 0 ]]; then
  echo "⚠️ No SQL init files found. Skipping Postgres generation."
else
  SQL_FILE="${SQL_FILES[0]}"

  echo "✔ Found SQL init file: $SQL_FILE"
  echo

  ############################################
  # ConfigMap for DB init
  ############################################
  cat > "$K8S_OUT_DIR/postgres-init-configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${PARENT_NAME}-postgres-init
  namespace: $NAMESPACE
data:
  init.sql: |
$(sed 's/^/    /' "$SQL_FILE")
EOF

  ############################################
  # PVC
  ############################################
  cat > "$K8S_OUT_DIR/postgres-pvc.yaml" <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PARENT_NAME}-postgres-pvc
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
EOF

  ############################################
  # Postgres Deployment with CORRECT env vars
  ############################################
  cat > "$K8S_OUT_DIR/postgres-deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${PARENT_NAME}-postgres
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${PARENT_NAME}-postgres
  template:
    metadata:
      labels:
        app: ${PARENT_NAME}-postgres
    spec:
      containers:
      - name: postgres
        image: postgres:16
        ports:
        - containerPort: 5432
        env:
        # PostgreSQL-specific environment variables (REQUIRED by postgres image)
        - name: POSTGRES_DB
          valueFrom:
            configMapKeyRef:
              name: ${PARENT_NAME}-config
              key: DATABASE_NAME
        - name: POSTGRES_USER
          valueFrom:
            secretKeyRef:
              name: ${PARENT_NAME}-secret
              key: DATABASE_USER
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: ${PARENT_NAME}-secret
              key: DATABASE_PASSWORD
        volumeMounts:
        - name: postgres-data
          mountPath: /var/lib/postgresql/data
          subPath: postgres  # Important: prevents permission issues
        - name: init-script
          mountPath: /docker-entrypoint-initdb.d
        readinessProbe:
          exec:
            command:
            - pg_isready
            - -U
            - postgres
          initialDelaySeconds: 15
          periodSeconds: 10
        livenessProbe:
          exec:
            command:
            - pg_isready
            - -U
            - postgres
          initialDelaySeconds: 30
          periodSeconds: 10
      volumes:
      - name: postgres-data
        persistentVolumeClaim:
          claimName: ${PARENT_NAME}-postgres-pvc
      - name: init-script
        configMap:
          name: ${PARENT_NAME}-postgres-init
EOF

  ############################################
  # Postgres Service
  ############################################
  cat > "$K8S_OUT_DIR/postgres-service.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${PARENT_NAME}-postgres
  namespace: $NAMESPACE
spec:
  selector:
    app: ${PARENT_NAME}-postgres
  ports:
  - port: 5432
    targetPort: 5432
  type: ClusterIP
EOF

  # IMPORTANT FIX: Always override DATABASE_HOST to use the correct service name
  # This ensures the application connects to the right Postgres service
  CONFIG_VARS["DATABASE_HOST"]="${PARENT_NAME}-postgres"
  echo "  Overriding DATABASE_HOST to: ${PARENT_NAME}-postgres"
fi

############################################
# Write ConfigMap
############################################
cat > "$CM_FILE" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${PARENT_NAME}-config
  namespace: $NAMESPACE
data:
EOF

for KEY in "${!CONFIG_VARS[@]}"; do
  echo "  $KEY: \"${CONFIG_VARS[$KEY]}\"" >> "$CM_FILE"
done

############################################
# Write Secret
############################################
cat > "$SEC_FILE" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${PARENT_NAME}-secret
  namespace: $NAMESPACE
type: Opaque
stringData:
EOF

for KEY in "${!SECRET_VARS[@]}"; do
  echo "  $KEY: \"${SECRET_VARS[$KEY]}\"" >> "$SEC_FILE"
done

echo "✅ Created ConfigMap and Secret"
echo

############################################
# 🔍 Dockerfiles
############################################
echo "🔍 Scanning for Dockerfiles..."

mapfile -t DOCKERFILES < <(find "$ROOT_DIR" -type f \
  \( -iname "Dockerfile" -o -iname "Dockerfile.*" -o -iname "dockerfile" \))

if [[ ${#DOCKERFILES[@]} -eq 0 ]]; then
  echo "❌ No Dockerfiles found. Exiting."
  exit 1
fi

echo
echo "🐳 Building Docker images + generating manifests..."
echo

for FILE in "${DOCKERFILES[@]}"; do
  DIR_PATH="$(dirname "$FILE")"
  DIR_NAME="$(basename "$DIR_PATH")"
  [[ "$DIR_PATH" == "$ROOT_DIR" ]] && DIR_NAME="root"

  IMAGE_NAME="${PARENT_NAME}-${DIR_NAME}:${TAG}"

  echo "  Building: $IMAGE_NAME"
  docker build -f "$FILE" -t "$IMAGE_NAME" "$DIR_PATH"
  
  kind load docker-image "$IMAGE_NAME" --name staging-cluster

  PORT=$(grep -i '^expose ' "$FILE" | awk '{print $2}' | head -1 || echo "8000")
  [[ -z "${PORT:-}" ]] && PORT=8000

  DEPLOY_NAME="${PARENT_NAME}-${DIR_NAME}"
  SERVICE_NAME="${PARENT_NAME}-${DIR_NAME}-service"

  cat > "$K8S_OUT_DIR/${DIR_NAME}-deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOY_NAME
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${PARENT_NAME}-${DIR_NAME}
  template:
    metadata:
      labels:
        app: ${PARENT_NAME}-${DIR_NAME}
    spec:
      containers:
      - name: ${DIR_NAME}
        image: $IMAGE_NAME
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: $PORT
        envFrom:
        - configMapRef:
            name: ${PARENT_NAME}-config
        - secretRef:
            name: ${PARENT_NAME}-secret
        readinessProbe:
          httpGet:
            path: /health
            port: $PORT
          initialDelaySeconds: 30  # Increased to allow DB connection
          periodSeconds: 5
          failureThreshold: 3
        livenessProbe:
          httpGet:
            path: /health
            port: $PORT
          initialDelaySeconds: 60  # Increased to allow DB connection
          periodSeconds: 10
          failureThreshold: 3
EOF

  cat > "$K8S_OUT_DIR/${DIR_NAME}-service.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: $SERVICE_NAME
  namespace: $NAMESPACE
spec:
  selector:
    app: ${PARENT_NAME}-${DIR_NAME}
  ports:
  - port: 80
    targetPort: $PORT
    protocol: TCP
  type: ClusterIP
EOF

done

echo
echo "🎉 Finished building images + generating Kubernetes manifests."
echo "📂 Output in: $K8S_OUT_DIR"
echo
echo "⚡ Deploy using:"
echo "   kubectl apply -f $K8S_OUT_DIR/"
echo
echo "⭐ Then select namespace:"
echo "   kubectl config set-context --current --namespace=$NAMESPACE"
echo
echo "📊 View resources:"
echo "   kubectl get all -n $NAMESPACE"
echo
echo "🔍 Check logs:"
echo "   kubectl logs -f deployment/${PARENT_NAME}-postgres -n $NAMESPACE"
echo "   kubectl logs -f deployment/\$(ls $K8S_OUT_DIR/*-deployment.yaml | head -1 | xargs basename -s -deployment.yaml) -n $NAMESPACE"