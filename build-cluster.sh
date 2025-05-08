#!/usr/bin/env bash

PRIVATE_KEY="${HOME}/.ssh/acit4430"
INV_FOLDER="cluster_inventory"

# terraform
(
    cd terraform;
    terraform init;
    terraform apply -auto-approve;
)

# wait for the cluster to be up
ansible-playbook wait_for_ssh.yaml -i "${INV_FOLDER}/inventory.ini"

# kubespray: install kubernetes on the cluster
docker run --rm -it --mount type=bind,source="$(pwd)/${INV_FOLDER}",dst=/inventory \
    --mount type=bind,source="${PRIVATE_KEY}",dst=/root/.ssh/id_rsa \
    quay.io/kubespray/kubespray:v2.27.0 bash -c "ansible-playbook -i /inventory/inventory.ini --private-key /root/.ssh/id_rsa cluster.yml --become-user=root --become"
