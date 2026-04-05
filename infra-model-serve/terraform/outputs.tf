output "floating_ip" {
  value       = openstack_networking_floatingip_v2.mms_fip.address
  description = "Public IP for SSH, MLflow (30601), model API (30608)"
}

output "ssh_command" {
  value       = "ssh ${var.ssh_user}@${openstack_networking_floatingip_v2.mms_fip.address}"
  description = "SSH command"
}

output "kubeconfig_copy_command" {
  value       = "scp ${var.ssh_user}@${openstack_networking_floatingip_v2.mms_fip.address}:/etc/rancher/k3s/k3s.yaml ~/.kube/mms-k3s.yaml"
  description = "Copy kubeconfig from VM; replace 127.0.0.1 with floating IP for remote kubectl"
}
