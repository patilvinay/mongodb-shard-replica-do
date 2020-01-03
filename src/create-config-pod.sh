#!/bin/bash
###
# This script is idempotent. It can be run as many times as you want
# To add a new shard, just give a higher count and run the script again
# For ex, when creating a 2 shard mongo cluster you would use
# mongo-bootstrap.sh 2
# And when adding a new shard you would run
# mongo-bootstrap.sh 3
# And new shard will get created, initialized automatically
# Note that extra nodes for the shard should exist before running
###
printf "\n======Ensuring mongo config is up and running===========\n"
echo "*** Spinning mongo-config"
kubectl apply -f mongo-config.yaml
n=$(kubectl get pods|grep -w 'mongo-config-.'|grep Running|wc -l)
while [ "$n" != "3" ]
do
echo "Waiting for pods to be ready"
sleep 5
n=$(kubectl get pods|grep -w 'mongo-config-.'|grep Running|wc -l)
done
echo "Mongo config pods are up"
echo "Configuring config servers as a replicaset"
nr=$(kubectl exec mongo-config-0 -- mongo --eval "rs.status();"|grep "NotYetInitialized"|wc -l)
if [[ $nr -gt 0 ]]
then
echo "Replicaset not yet initialized, initializing"
kubectl exec mongo-config-0 -- mongo --eval "rs.initiate({_id: \"crs\", configsvr: true, members: [ {_id: 0, host: \"mongo-config-0.mongo-config-svc.default.svc.cluster.local:27017\"}, {_id: 1, host: \"mongo-config-1.mongo-config-svc.default.svc.cluster.local:27017\"}, {_id: 2, host: \"mongo-config-2.mongo-config-svc.default.svc.cluster.local:27017\"} ]});"
else
echo "Replicaset already initialized, skipping"
fi
