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

shardcount=3;


function create_storage_class() {
  #*************  STEP 0  *****************
  printf "\n=====creating storage class ==========\n"
  kubectl apply -f storage-class-xfs.yaml
}
#*************  STEP 1  *****************
function keyfile() {

  printf "\n======Ensuring mongodb key file exists===========\n"
  #CREATE MONGODB-KEYFILE WHICH WILL BE USED IN ALL MONGO NODES.
  adminPwd=$1

  kubectl get secrets/mongodb-key
  if [[ $? -ne 0 ]]; then
    echo "*** mongodb-keyfile does not exist. Creating one..."
    openssl rand -base64 741 >mongodb-keyfile
    echo "Adding to kube secrets"
    kubectl create secret generic mongodb-key --from-file=mongodb-keyfile
    kubectl create secret generic mongodb-pwd --from-literal=pwd="$adminPwd"
  else
    echo "mongodob-keyfile exists"
  fi
}

function create_mongo_config() {
  #*************  STEP 2  *****************
  printf "\n======Ensuring mongo config is up and running===========\n"
  echo "*** Spinning mongo-config"
  kubectl apply -f mongo-config.yaml
  n=$(kubectl get pods | grep -w 'mongo-config-.' | grep Running | wc -l)
  while [ "$n" != "3" ]; do
    echo "Waiting for pods to be ready"
    sleep 5
    n=$(kubectl get pods | grep -w 'mongo-config-.' | grep Running | wc -l)
  done
  echo "Mongo config pods are up"
  echo "Configuring config servers as a replicaset"
  nr=$(kubectl exec mongo-config-0 -- mongo --eval "rs.status();" | grep "NotYetInitialized" | wc -l)
  if [[ $nr -gt 0 ]]; then
    echo "Replicaset not yet initialized, initializing"
    kubectl exec mongo-config-0 -- mongo --eval "rs.initiate({_id: \"crs\", configsvr: true, members: [ {_id: 0, host: \"mongo-config-0.mongo-config-svc.default.svc.cluster.local:27017\"}, {_id: 1, host: \"mongo-config-1.mongo-config-svc.default.svc.cluster.local:27017\"}, {_id: 2, host: \"mongo-config-2.mongo-config-svc.default.svc.cluster.local:27017\"} ]});"
  else
    echo "Replicaset already initialized, skipping"
  fi
}

function create_mongo_query_router() {
  #*************  STEP 3  *****************
  printf "\n======Ensuring mongo query routers are up and running===========\n"
  kubectl apply -f mongo-qr.yaml
  nqr=$(kubectl get pods | grep "mongo-qr" | grep "Running" | wc -l)
  fresh=0
  while [[ $nqr -lt 1 ]]; do
    echo "Waiting for pods to be ready"
    sleep 5
    fresh=1
    nqr=$(kubectl get pods | grep "mongo-qr" | grep "Running" | wc -l)
  done
  echo "Query router pods are up ($nqr)"
  if [[ $fresh -eq 1 ]]; then echo "Sleeping 30s for routers to be initialized" && sleep 30; fi
  echo "Creating admin user. You can ignore if this step fails because user already exists."
  qrPod=$(kubectl get pods | grep "mongo-qr" | head -1 | awk '{print $1}')
  kubectl exec $qrPod -- mongo --eval "db.getSiblingDB(\"admin\").createUser({user: \"admin\", pwd: \"$adminPwd\", roles: [ { role: \"root\", db: \"admin\" } ] });"

}

function create_mongo_shard() {
  #*************  STEP 4  *****************
   export shards=0
  shardcount=$1;
  replica=$2
  printf "\n======Ensuring mongo shards are up and running===========\n"
  printf "\n======Shards $shardcount  and replica $replica===========\n"
  printf "\n=========================================================\n"
 
  while [[ $shards -lt $shardcount ]]; do
    echo "*** Spinning mongo-shard$shards"
    #sed "s/shard0/shard$shards/replicas: 3/replicas: $replica$g" mongo-shard.yaml >mongo-shard$shards.yaml
    sed "s/shard0/shard$shards/g; s/replicas: 3/replicas: $replica/g" mongo-shard.yaml  >mongo-shard$shards.yaml
    exit 1
    kubectl apply -f mongo-shard$shards.yaml
    n=$(kubectl get pods | grep -w "mongo-shard$shards-." | grep Running | wc -l)
    fresh=0
    while [ "$n" != "3" ]; do
      echo "Waiting for pods to be ready"
      sleep 5
      fresh=1
      n=$(kubectl get pods | grep -w "mongo-shard$shards-." | grep Running | wc -l)
    done
    echo "Mongo shard$shards pods are up"
    if [[ $fresh -eq 1 ]]; then echo 'Sleeping for 20s' && sleep 20; fi
    nr=$(kubectl exec mongo-shard$shards-0 -- mongo --eval "rs.status();" | grep "NotYetInitialized" | wc -l)
    if [[ $nr -gt 0 ]]; then
      echo "Replicaset not yet initialized, initializing"
      kubectl exec mongo-shard$shards-0 -- mongo --eval "rs.initiate({_id: \"shard$shards\", members: [ {_id: 0, host: \"mongo-shard$shards-0.mongo-shard$shards-svc.default.svc.cluster.local:27017\"}, {_id: 1, host: \"mongo-shard$shards-1.mongo-shard$shards-svc.default.svc.cluster.local:27017\"}, {_id: 2, host: \"mongo-shard$shards-2.mongo-shard$shards-svc.default.svc.cluster.local:27017\"} ]});"
      sleep 10
    else
      echo "Replicaset already initialized, skipping"
    fi
    shardIdRows=$(kubectl exec $qrPod -- mongo admin -u admin -p "$adminPwd" --eval "sh.status();" | grep "shard$shards" | wc -l)
    if [[ $shardIdRows -gt 0 ]]; then
      echo "Shard shard$shards is already added to mongos qr. Skipping addShard"
    else
      echo "Shard shard$shards is not yet added to mongos qr. Invoking addShard"
      kubectl exec $qrPod -- mongo admin -u admin -p "$adminPwd" --eval "sh.addShard(\"shard$shards/mongo-shard$shards-0.mongo-shard$shards-svc.default.svc.cluster.local:27017\");"
    fi
    printf "===\n\n"
    shards=$(($shards + 1))
  done
}
 echo "otps: $opt" ;
while getopts ":a:s:p:e:r:" opt; do
  case $opt in
    s)
      shardcount=$OPTARG
       echo "Sharding: $shardcount" >&2
      ;;

    p)
      adminPwd=$OPTARG
      echo "Password for mongodb keyfile: $adminPwd" >&2
      ;;
    r)
     replica=$OPTARG
     echo "replica: $replica" >&2
      ;;
    e)
    options=$OPTARG
    
    ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      exit 1
      ;;
  esac
done




 
    case $options in
      all)
         echo "executing all" >&2
          create_storage_class
          keyfile $adminPwd
          create_mongo_config
          create_mongo_shard

         ;;
      csc)
         echo "creating storage class" >&2
         create_storage_class
         ;;
         
      ckf)
         echo "creating keyfile" >&2
         keyfile $adminPwd
         ;;
      cmqr)  
         echo "creating mongo query router" >&2  
         ;;
      cms)
          echo "creating mongo $shardcount shards" >&2  
           create_mongo_shard $shardcount $replica 
    esac
 
