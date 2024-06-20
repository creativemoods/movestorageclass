#!/bin/bash

NAMESPACE=mynamespace
STORAGECLASS=exoscale-sbs
DEPLOY=mydeploy
PVC=mypvc
SIZE=10Gi

# Scale to 0
kubectl scale --replicas=0 deploy/$DEPLOY -n $NAMESPACE

# Create PV with new storageclass and same size
cat > /tmp/newpvc.yaml <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: tmppvc
  namespace: $NAMESPACE
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: $SIZE
  storageClassName: $STORAGECLASS
EOF
kubectl apply -f /tmp/newpvc.yaml

cat > /tmp/datamover.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: data-mover
  name: data-mover
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: data-mover
  template:
    metadata:
      labels:
        app: data-mover
    spec:
      containers:
      - args:
        - -c
        - while true; do ping localhost; sleep 60;done
        command:
        - /bin/sh
        image: quay.io/quay/busybox
        name: data-mover
        volumeMounts:
        - mountPath: /source
          name: source
        - mountPath: /destination
          name: destination
      restartPolicy: Always
      volumes:
      - name: source
        persistentVolumeClaim:
          claimName: $PVC
      - name: destination
        persistentVolumeClaim:
          claimName: tmppvc
EOF
kubectl apply -f /tmp/datamover.yaml

# Wait for pod to start up
kubectl wait -n $NAMESPACE deploy/data-mover --for condition=available --timeout=120s

# Copy contents from source to destination
kubectl exec -n $NAMESPACE deploy/data-mover -- sh -c "cp -aR /source/* /destination/"

# Destroy datamover
kubectl -n $NAMESPACE delete deploy/data-mover

# Delete original PVC
OLDPV=$(kubectl get pvc $PVC -n $NAMESPACE -o=json | jq -r '.spec.volumeName')
kubectl -n $NAMESPACE delete pvc/$PVC

# Change Retain Policy on new PV so that we can delete its PVC while keeping the PV
PV=$(kubectl get pvc tmppvc -n $NAMESPACE -o=json | jq -r '.spec.volumeName')
kubectl patch pv $PV -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'

# Delete new PVC
kubectl -n $NAMESPACE delete pvc/tmppvc

# Remove claimref from PV
kubectl patch pv $PV --type json -p '[{"op": "remove", "path": "/spec/claimRef"}]'

# Recreate PVC with same name
cat > /tmp/bindpvc.yaml <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC
  namespace: $NAMESPACE
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: $SIZE
  volumeName: $PV
  storageClassName: $STORAGECLASS
EOF
kubectl apply -f /tmp/bindpvc.yaml

# Wait for bind
kubectl wait -n $NAMESPACE pvc/$PVC --for=jsonpath='{.status.phase}'=Bound

# Scale back to 1
kubectl scale --replicas=1 deploy/$DEPLOY -n $NAMESPACE

# Cleanup
kubectl delete $OLDPV
rm -f /tmp/newpvc.yaml
rm -f /tmp/datamover.yaml
rm -f /tmp/bindpvc.yaml
