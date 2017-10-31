#!/bin/bash

NODE_TYPE=$1
AZUREUSER=azureuser
ARTIFACTS_URL_PREFIX=fabric
NODE_INDEX=$2
CA_PREFIX=fabric-ca_host
ORDERER_PREFIX=fabric-orderer
PEER_PREFIX=fabric-peer
CA_USER=ca_user
CA_PASSWORD=ca_password
PREFIX=fabric
INDEX=0
ARCH=linux-amd64
VERSION=1.0.2
IS_TLS_ENABLED=false

#PEER_NUM=
#CA_NUM=
#ORDERER_NUM=

FABRIC_VERSION=x86_64-1.0.2

# TODO: extract those from the configuration
PEER_ORG_DOMAIN="org1.triangu.com"
ORDERER_ORG_DOMAIN="triangu.com"

function generate_artifacts {
    echo "Generating network artifacts..."

    # Retrieve configuration templates
    wget -N ${ARTIFACTS_URL_PREFIX}/configtx_template.yaml
    wget -N ${ARTIFACTS_URL_PREFIX}/crypto-config_template.yaml

    echo Retrieve tools
    # TODO: download less stuff?

    if [ ! -f ./release.tar.gz ]; then
        curl -qL https://nexus.hyperledger.org/content/repositories/releases/org/hyperledger/fabric/hyperledger-fabric/${ARCH}-${VERSION}/hyperledger-fabric-${ARCH}-${VERSION}.tar.gz  -o release.tar.gz
    fi
    tar -xvf release.tar.gz

    # Set up environment
    os_arch=$(echo "$(uname -s)-amd64" | awk '{print tolower($0)}')
    export FABRIC_CFG_PATH=$PWD

echo     Parse configuration templates
    sed -e "s/{{PREFIX}}/${PREFIX}/g" crypto-config_template.yaml > crypto-config_tmp.yaml
    sed -e "s/{{PREFIX}}/${PREFIX}/g" configtx_template.yaml > configtx_tmp.yaml

    sed -e "s/{{.Index}}/${INDEX}/g" crypto-config_tmp.yaml > crypto-config.yaml
    sed -e "s/{{.Index}}/${INDEX}/g" configtx_tmp.yaml > configtx.yaml
    
    rm crypto-config_tmp.yaml
    rm configtx_tmp.yaml
    
echo    Generate crypto config
    ./bin/cryptogen generate --config=./crypto-config.yaml

echo     Generate genesis block
    ./bin/configtxgen -profile TwoOrgs -outputBlock orderer.block

echo     Generate transaction configuration
    ./bin/configtxgen -profile TwoOrgs -outputCreateChannelTx channel.tx -channelID mychannel
}

function get_artifacts {
    echo "Retrieving network artifacts..."

    # Copy the artifacts from the first CA host
    scp -i ./.ssh/fabric_ca.key -o StrictHostKeyChecking=no "${CA_PREFIX}:~/${ARTIFACTS_URL_PREFIX}/configtx.yaml" .
    scp -i ./.ssh/fabric_ca.key -o StrictHostKeyChecking=no "${CA_PREFIX}:~/${ARTIFACTS_URL_PREFIX}/orderer.block" .
    scp -i ./.ssh/fabric_ca.key -o StrictHostKeyChecking=no "${CA_PREFIX}:~/${ARTIFACTS_URL_PREFIX}/channel.tx" .
    scp -i ./.ssh/fabric_ca.key -o StrictHostKeyChecking=no -r "${CA_PREFIX}:~/${ARTIFACTS_URL_PREFIX}/crypto-config" .
    sudo chown $USER.$USER ~/${ARTIFACTS_URL_PREFIX}/configtx.yaml ~/${ARTIFACTS_URL_PREFIX}/orderer.block ~/${ARTIFACTS_URL_PREFIX}/channel.tx
#    sudo chown -r $USER.$USER ~/crypto-config
}

function distribute_ssh_key {
#TODO: Change distributing logic 
    echo "Generating ssh key..."

    # Generate new ssh key pair
    ssh-keygen -q -t rsa -N "" -f ~/.ssh/id_rsa

    # Authorize new key
    cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
    chmod 700 ~/.ssh
    chmod 600 ~/.ssh/authorized_keys

    # Expose private key to other nodes
    while true; do echo -e "HTTP/1.1 200 OK\n\n$(cat ~/.ssh/id_rsa)" | nc -l -p 1515; done &
}

function get_ssh_key {
#TODO: Change distributing logic 
    echo "Retrieving ssh key..."

    # Get the ssh key from the first CA host
    # TODO: loop here waiting for the request to succeed, instead of sequencing via the template dependencies?
    curl "http://${CA_PREFIX}:1515/" -o ~/.ssh/id_rsa || exit 1

    # Fix permissions
    chmod 700 ~/.ssh
    chmod 400 ~/.ssh/id_rsa
}

function install_ca {
    echo "Installing Membership Service..."

    cacert="/etc/hyperledger/fabric-ca-server-config/${PEER_ORG_DOMAIN}-cert.pem"
    cakey="/etc/hyperledger/fabric-ca-server-config/$(basename crypto-config/peerOrganizations/${PEER_ORG_DOMAIN}/ca/*_sk)"

    # Pull Docker image
    sudo docker pull hyperledger/fabric-ca:${FABRIC_VERSION}

    # Start CA
    sudo docker run -d --restart=always -p 7054:7054 \
        -v $HOME/${ARTIFACTS_URL_PREFIX}/crypto-config/peerOrganizations/${PEER_ORG_DOMAIN}/ca:/etc/hyperledger/fabric-ca-server-config \
        hyperledger/fabric-ca:${FABRIC_VERSION} fabric-ca-server start \
        --ca.certfile $cacert \
        --ca.keyfile $cakey \
        -b "${CA_USER}":"${CA_PASSWORD}"
}

function install_orderer {
    echo "Installing Orderer..."

    # Pull Docker image
    sudo docker pull hyperledger/fabric-orderer:${FABRIC_VERSION}

    # Start Orderer
    sudo docker run -d --restart=always -p 7050:7050 \
        -e ORDERER_GENERAL_GENESISMETHOD=file \
        -e ORDERER_GENERAL_GENESISFILE=/var/hyperledger/orderer/orderer.block \
        -e ORDERER_GENERAL_LOCALMSPID=OrdererMSP \
        -e ORDERER_GENERAL_LOCALMSPDIR=/var/hyperledger/orderer/msp \
        -e ORDERER_GENERAL_GENESISPROFILE=TwoOrgs \
        -e ORDERER_GENERAL_LOGLEVEL=debug \
        -e ORDERER_GENERAL_LISTENADDRESS=0.0.0.0 \
        -e ORDERER_GENERAL_TLS_ENABLED=$IS_TLS_ENABLED \
        -v $HOME/${ARTIFACTS_URL_PREFIX}/orderer.block:/var/hyperledger/orderer/orderer.block \
        -v $HOME/${ARTIFACTS_URL_PREFIX}/crypto-config/ordererOrganizations/${ORDERER_ORG_DOMAIN}/orderers/${ORDERER_PREFIX}0.${ORDERER_ORG_DOMAIN}/msp:/var/hyperledger/orderer/msp \
        -v $HOME/${ARTIFACTS_URL_PREFIX}/crypto-config/ordererOrganizations/${ORDERER_ORG_DOMAIN}/orderers/${ORDERER_PREFIX}0.${ORDERER_ORG_DOMAIN}/tls:/var/hyperledger/orderer/tls \
        hyperledger/fabric-orderer:${FABRIC_VERSION} orderer
}

function install_peer {
    echo "Installing Peer..."

    # Pull Docker image
    sudo docker pull hyperledger/fabric-peer:${FABRIC_VERSION}

    # The Peer needs this image to cerate chaincode containers
    sudo docker pull hyperledger/fabric-ccenv:${FABRIC_VERSION}

    # Start Peer
    sudo docker run -d --restart=always -p 7051:7051 -p 7053:7053 \
        -e CORE_PEER_ID=${PEER_PREFIX}${NODE_INDEX}.${PEER_ORG_DOMAIN} \
        -e CORE_PEER_LOCALMSPID=Org1MSP \
        -e CORE_VM_ENDPOINT=unix:///host/var/run/docker.sock \
        -e CORE_PEER_TLS_ENABLED=${IS_TLS_ENABLED} \
        -e CORE_CHIANCODE_LOGGING_LEVEL=DEBUG \
        -v /var/run:/host/var/run \
        -v $HOME/${ARTIFACTS_URL_PREFIX}/channel.tx:/etc/hyperledger/fabric/channel.tx \
        -v $HOME/${ARTIFACTS_URL_PREFIX}/configtx.yaml:/etc/hyperledger/fabric/configtx.yaml \
        -v $HOME/${ARTIFACTS_URL_PREFIX}/crypto-config/peerOrganizations/${PEER_ORG_DOMAIN}/peers/${PEER_PREFIX}${NODE_INDEX}.${PEER_ORG_DOMAIN}/msp:/etc/hyperledger/fabric/msp \
        -v $HOME/${ARTIFACTS_URL_PREFIX}/crypto-config/peerOrganizations/${PEER_ORG_DOMAIN}/peers/${PEER_PREFIX}${NODE_INDEX}.${PEER_ORG_DOMAIN}/tls:/etc/hyperledger/fabric/tls \
        hyperledger/fabric-peer:${FABRIC_VERSION} peer node start --peer-defaultchain=false
}

function install_cli {
    echo "Installing Client..."

    # Pull Docker image
    sudo docker pull hyperledger/fabric-tools:${FABRIC_VERSION}

    # Start Client
    sudo docker run -d --restart=always -p 3080:80 \
        -e CORE_PEER_ID=cli \
        -e CORE_PEER_ADDRESS=172.31.24.129:7051 \
        -e CORE_PEER_LOCALMSPID=Org1MSP \
        -e CORE_PEER_TLS_ENABLED="${IS_TLS_ENABLED}" \
        -e CORE_PEER_TLS_CERT_FILE=/etc/hyperledger/fabric/msp/sampleconfig/tls/server.crt \
        -e CORE_PEER_TLS_KEY_FILE=/etc/hyperledger/fabric/msp/sampleconfig/tls/server.key \
        -e CORE_PEER_TLS_ROOTCERT_FILE=/etc/hyperledger/fabric/msp/sampleconfig/tls/ca.crt \
        -e CORE_PEER_MSPCONFIGPATH=/etc/hyperledger/fabric/users/msp \
        -e CORE_VM_ENDPOINT=unix:///host/var/run/docker.sock \
        -e ORDERER_CA=/etc/hyperledger/orderer/msp/tlscacerts/tlsca.triangu.com-cert.pem
        -v /var/run:/host/var/run \
        -v $HOME/${ARTIFACTS_URL_PREFIX}/channel.tx:/etc/hyperledger/fabric/channel.tx \
        -v $HOME/${ARTIFACTS_URL_PREFIX}/configtx.yaml:/etc/hyperledger/fabric/configtx.yaml \
        -v $HOME/${ARTIFACTS_URL_PREFIX}/crypto-config.yaml:/etc/hyperledger/fabric/crypto-config.yaml \
        -v $HOME/${ARTIFACTS_URL_PREFIX}/crypto-config/peerOrganizations/${PEER_ORG_DOMAIN}/peers/${PEER_PREFIX}0.${PEER_ORG_DOMAIN}:/etc/hyperledger/fabric/msp/sampleconfig \
        -v $HOME/${ARTIFACTS_URL_PREFIX}/crypto-config/peerOrganizations/${PEER_ORG_DOMAIN}/users/Admin@${PEER_ORG_DOMAIN}/msp:/etc/hyperledger/fabric/users/msp \
        -v $HOME/${ARTIFACTS_URL_PREFIX}/crypto-config/ordererOrganizations/${ORDERER_ORG_DOMAIN}/orderers/${ORDERER_PREFIX}0.${ORDERER_ORG_DOMAIN}:/etc/hyperledger/orderer \
        hyperledger/fabric-tools:${FABRIC_VERSION} sleep 40000
}


# Jump to node-specific steps

case "${NODE_TYPE}" in
"ca")
    generate_artifacts
#    distribute_ssh_key
    install_ca
    ;;
"orderer")
#    get_ssh_key
    get_artifacts
    install_orderer
    ;;
"peer")
#    get_ssh_key
    get_artifacts
    install_peer
    ;;
"cli")
#    get_artifacts
    install_cli
    ;;
"*")
    echo "Invalid node type, exiting."
    exit 1
    ;;
esac
