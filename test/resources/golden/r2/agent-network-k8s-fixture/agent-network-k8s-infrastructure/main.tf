terraform {
  required_providers {
    vultr = { source = "vultr/vultr", version = "~> 2.0" }
  }
}

provider "vultr" {
  # api key comes from VULTR_API_KEY in the environment
}

# Every label derives from one resolved name (Compute Name Standard §3), which
# defaults to the profile. Templates never branch on whether an override was
# supplied — that decision was made once, in Clojure. There is no firewall
# resource and no SSH key: the nodes are VKE-managed, every operation goes
# through the kubeconfig, and the only public surface is the load balancer
# the cloud controller creates from the Traefik Service.
resource "vultr_kubernetes" "agent_network_k8s" {
  region  = "ams"
  label   = "agent-network-k8s-fixture"
  version = "v1.35.2+1"

  node_pools {
    node_quantity = 2
    plan          = "vc2-2c-4gb"
    label         = "agent-network-k8s-fixture"
  }

  lifecycle { prevent_destroy = true }
}

# The deployment-owned registry the in-cluster kaniko build pushes the agent
# image to and the kubelet pulls it from. Vultr registry names accept
# lowercase alphanumerics only, so this name is the resolved compute name with
# every other character removed.
resource "vultr_container_registry" "agent_network_k8s" {
  name   = "agentnetworkk8sfixture"
  region = "ams"
  plan   = "start_up"
  public = false
}

output "params" {
  value = {
    name       = "agent-network-k8s-fixture"
    cluster-id = vultr_kubernetes.agent_network_k8s.id
    endpoint   = vultr_kubernetes.agent_network_k8s.endpoint
  }
}

output "kubeconfig-b64" {
  value     = vultr_kubernetes.agent_network_k8s.kube_config
  sensitive = true
}

output "registry-urn" {
  value = vultr_container_registry.agent_network_k8s.urn
}

output "registry-username" {
  value     = vultr_container_registry.agent_network_k8s.root_user["username"]
  sensitive = true
}

output "registry-password" {
  value     = vultr_container_registry.agent_network_k8s.root_user["password"]
  sensitive = true
}
