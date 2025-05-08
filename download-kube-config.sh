#!/usr/bin/env bash

# download kubeconfig
sudo $(which ansible-playbook) config-local-kubectl.yaml --private-key="${HOME}/.ssh/acit4430" -i cluster_inventory/inventory.ini --become-user=root --become
