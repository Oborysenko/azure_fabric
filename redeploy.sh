#!/bin/bash

docker kill $(docker ps -q)
docker rm $(docker ps -a -q)

sudo rm -rf ./crypto-config ./configtx.yaml ./orderer.block ./channel.tx ./crypto-config.yaml
cd ~/azure_fabric/ && git pull && cp ./* ../ && cd ~/
