terraform {
  required_providers {
    openstack = {
      source = "terraform-provider-openstack/openstack"
      #version = "~> 1.53.0"
    }
  }
}

provider "openstack" {
  cloud = "openstack" # defined in .config/openstack/clouds.yaml
}

# create the kubernetes nodes
resource "openstack_compute_instance_v2" "kube_node" {
  name            = "terraform_slave_${count.index}"
  image_name      = "Ubuntu 22.04-LTS (Jammy Jellyfish)"
  flavor_name     = "aem.2c4r.50g"
  security_groups = ["default", "acit4430 io7"]
  key_pair        = "thomas laptop acit4430"
  count           = 4

  network {
    name = "oslomet"
  }
}

# create the volumes for the worker nodes
resource "openstack_blockstorage_volume_v3" "kube_node_vol" {
  name  = "kube_node_vol_${count.index}"
  size  = 10
  count = 4
}

# attach the volumes to the worker nodes
resource "openstack_compute_volume_attach_v2" "kube_node_vol_attach" {
  count       = 4
  instance_id = openstack_compute_instance_v2.kube_node[count.index].id
  volume_id   = openstack_blockstorage_volume_v3.kube_node_vol[count.index].id
}

output "slave_ip" {
  value = [for i in openstack_compute_instance_v2.kube_node : i.access_ip_v4]
}
