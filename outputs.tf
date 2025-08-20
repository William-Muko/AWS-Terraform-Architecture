# outputs.tf

output "alb_dns_name" {
  description = "The DNS name of the Application Load Balancer. This is the URL to access your website."
  value       = aws_lb.web_alb.dns_name
}

output "alb_zone_id" {
  description = "The canonical hosted zone ID of the load balancer (to be used in a Route 53 Alias record)."
  value       = aws_lb.web_alb.zone_id
}

output "vpc_id" {
  description = "The ID of the created VPC."
  value       = aws_vpc.mara.id
}

output "public_subnet_ids" {
  description = "The IDs of the created public subnets."
  value       = [aws_subnet.public.id, aws_subnet.public_b.id]
}

output "web_sg_id" {
  description = "The ID of the security group for the web instances."
  value       = aws_security_group.web_sg.id
}

output "alb_sg_id" {
  description = "The ID of the security group for the Application Load Balancer."
  value       = aws_security_group.alb_sg.id
}

output "target_group_arn" {
  description = "The ARN of the target group for the web instances."
  value       = aws_lb_target_group.web_tg.arn
}

output "asg_name" {
  description = "The name of the Auto Scaling Group."
  value       = aws_autoscaling_group.web_asg.name
}