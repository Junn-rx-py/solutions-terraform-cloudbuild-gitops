output "load_balancer_ip" {
  description = "The IP address of the Regional Load Balancer Frontend"
  value       = google_compute_forwarding_rule.management_lb_frontend.ip_address
}

output "cloud_run_urls" {
  description = "The URLs of the deployed Cloud Run services"
  value = {
    for k, v in google_cloud_run_v2_service.services : k => v.uri
  }
}