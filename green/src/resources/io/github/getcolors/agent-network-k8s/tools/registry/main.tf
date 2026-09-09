terraform {
  required_providers {
    vultr = { source = "vultr/vultr", version = "~> 2.0" }
  }
}

provider "vultr" {
  # api key comes from VULTR_API_KEY in the environment
}

# The deployment-owned registry the in-cluster kaniko build pushes the agent
# image to and the kubelet pulls it from. Vultr registry names accept
# lowercase alphanumerics only, so this name is the resolved compute name with
# every other character removed.
resource "vultr_container_registry" "agent_network_k8s" {
  name   = "<{ registry-name }>"
  region = "<{ vultr-region }>"
  plan   = "<{ vultr-registry-plan }>"
  public = false
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
