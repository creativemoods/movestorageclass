#!/bin/bash

NAMESPACE=mynamespace
STORAGECLASS=exoscale-sbs
DEPLOY=mydeploy
PVC=mypvc
SIZE=10Gi

# Scale to 0
echo -n "Scaling deployment to 0: "
kubectl scale --replicas=0 deploy/$DEPLOY -n $NAMESPACE
[ $? -eq 0 ] && echo "" || exit 1

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
echo -n "Creating PV and PVC with storage class $STORAGECLASS: "
kubectl apply -f /tmp/newpvc.yaml
[ $? -eq 0 ] && echo "" || exit 1

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
echo -n "Creating datamover: "
kubectl apply -f /tmp/datamover.yaml
[ $? -eq 0 ] && echo "" || exit 1

# Wait for pod to start up
echo -n "Waiting for datamover: "
kubectl wait -n $NAMESPACE deploy/data-mover --for condition=available --timeout=120s
[ $? -eq 0 ] && echo "" || exit 1

# Copy contents from source to destination
echo -n "Copying contents from source to new destination: "
kubectl exec -n $NAMESPACE deploy/data-mover -- sh -c "cp -aR /source/* /destination/"
[ $? -eq 0 ] && echo "" || exit 1

# Destroy datamover
echo -n "Deleting datamover: "
kubectl -n $NAMESPACE delete deploy/data-mover
[ $? -eq 0 ] && echo "" || exit 1

# Delete original PVC
OLDPV=$(kubectl get pvc $PVC -n $NAMESPACE -o=json | jq -r '.spec.volumeName')
echo "Old PV is $OLDPV."
echo -n "Deleting old PVC: "
kubectl -n $NAMESPACE delete pvc/$PVC
[ $? -eq 0 ] && echo "" || exit 1

# Change Retain Policy on new PV so that we can delete its PVC while keeping the PV
PV=$(kubectl get pvc tmppvc -n $NAMESPACE -o=json | jq -r '.spec.volumeName')
echo "New PV is $PV."
echo -n "Patching new PV and setting Reclaim Policy to Retain: "
kubectl patch pv $PV -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
[ $? -eq 0 ] && echo "" || exit 1

# Delete new PVC
echo -n "Deleting new PVC: "
kubectl -n $NAMESPACE delete pvc/tmppvc
[ $? -eq 0 ] && echo "" || exit 1

# Remove claimref from PV
echo -n "Removing claimref from new PV: "
kubectl patch pv $PV --type json -p '[{"op": "remove", "path": "/spec/claimRef"}]'
[ $? -eq 0 ] && echo "" || exit 1

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
echo -n "Recreating PVC with original name: "
kubectl apply -f /tmp/bindpvc.yaml
[ $? -eq 0 ] && echo "" || exit 1

# Wait for bind
echo -n "Waiting for PVC to be bound: "
kubectl wait -n $NAMESPACE pvc/$PVC --for=jsonpath='{.status.phase}'=Bound
[ $? -eq 0 ] && echo "" || exit 1

# Scale back to 1
echo -n "Scaling back application to 1: "
kubectl scale --replicas=1 deploy/$DEPLOY -n $NAMESPACE
[ $? -eq 0 ] && echo "" || exit 1

# Cleanup
echo -n "Cleaning up: "
kubectl delete --ignore-not-found pv/$OLDPV
[ $? -eq 0 ] && echo "" || exit 1
rm -f /tmp/newpvc.yaml
rm -f /tmp/datamover.yaml
rm -f /tmp/bindpvc.yaml
