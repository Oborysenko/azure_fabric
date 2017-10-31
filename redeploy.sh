#!/bin/bash

sudo docker kill $(sudo docker ps -q)
sudo docker rm $(sudo docker ps -a -q)

git stash
sudo rm -rf ./crypto-config ./configtx.yaml ./orderer.block ./channel.tx ./crypto-config.yaml
cd ~/fabric/ && git pull && cp -r ./* ../ && cd ~/
chmod +x ~/fabric/redeploy.sh
chmod +x ~/fabric/configure-fabric-azureuser.sh
chmod +x ~/fabric/yeasy_conf.sh
