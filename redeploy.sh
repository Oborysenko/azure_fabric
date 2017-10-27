#!/bin/bash

docker kill $(sudo docker ps -q)
docker rm $(sudo docker ps -a -q)

sudo rm -rf ./crypto-config ./configtx.yaml ./orderer.block ./channel.tx ./crypto-config.yaml
cd ~/fabric/ && git pull && cp ./* ../ && cd ~/
