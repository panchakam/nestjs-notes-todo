terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.3.0"
    }
  }

  required_version = ">= 1.2.0"
}

variable "aws_region" {
  default = "eu-central-1"
}

variable "domain_name" {
  default = "chak.website"
}
variable "subdomain_name" {
  default = "api"
}

variable "hosted_zone" {
  default = "Z00775391KQEU4GEOCDU1"
}

variable "repository_url" {
  default = "701584987364.dkr.ecr.eu-central-1.amazonaws.com/notes-todo-repository"
}

variable "vpc_cidr_block" {
  default = "10.0.0.0/16"
}

variable "subnet_cidr_blocks" {
  default = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

provider "aws" {
  region  = var.aws_region
}

data "aws_availability_zones" "all" {}

resource "aws_vpc" "notes_todo_vpc" {
  cidr_block = var.vpc_cidr_block

  tags = {
    Name = "notes-todo-vpc"
  }
}

resource "aws_subnet" "notes_todo_subnets" {
  count             = length(var.subnet_cidr_blocks)
  vpc_id            = aws_vpc.notes_todo_vpc.id
  cidr_block        = var.subnet_cidr_blocks[count.index]
  availability_zone = data.aws_availability_zones.all.names[count.index]

  tags = {
    Name = "notes-todo-subnet-${count.index + 1}"
  }
}

resource "aws_internet_gateway" "notes_todo_igw" {
  vpc_id = aws_vpc.notes_todo_vpc.id
}

resource "aws_route_table_association" "notes_todo_route_association" {
  subnet_id      = aws_subnet.notes_todo_subnets[0].id
  route_table_id = aws_vpc.notes_todo_vpc.main_route_table_id
}

resource "aws_route_table_association" "notes_todo_route_association2" {
  subnet_id      = aws_subnet.notes_todo_subnets[1].id
  route_table_id = aws_vpc.notes_todo_vpc.main_route_table_id
}

resource "aws_route_table_association" "notes_todo_route_association3" {
  subnet_id      = aws_subnet.notes_todo_subnets[2].id
  route_table_id = aws_vpc.notes_todo_vpc.main_route_table_id
}

resource "aws_route" "notes_todo_internet_route" {
  route_table_id            = aws_vpc.notes_todo_vpc.main_route_table_id
  destination_cidr_block    = "0.0.0.0/0"
  gateway_id                = aws_internet_gateway.notes_todo_igw.id
}



resource "aws_ecs_cluster" "notes_todo_cluster" {
  name = "notes-todo-cluster"
}

resource "aws_ecs_task_definition" "notes_todo_task" {
  family                   = "notes-todo-task"
  container_definitions    = <<DEFINITION
  [
    {
      "name": "notes-todo-task",
      "image": "${var.repository_url}",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 3000,
          "hostPort": 3000
        }
      ],
      "memory": 1024,
      "cpu": 512,
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
            "awslogs-group": "${aws_cloudwatch_log_group.notes_todo_log_group.name}",
            "awslogs-region": "${var.aws_region}",
            "awslogs-stream-prefix": "ecs"
        }
      }
    }
  ]
  DEFINITION
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  memory                   = 1024
  cpu                      = 512
  execution_role_arn       = "${aws_iam_role.ecsTaskExecutionRole.arn}"
}

resource "aws_iam_role" "ecsTaskExecutionRole" {
  name               = "ecsTaskExecutionRole"
  assume_role_policy = "${data.aws_iam_policy_document.assume_role_policy.json}"
}

data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "ecsTaskExecutionRole_policy" {
  role       = "${aws_iam_role.ecsTaskExecutionRole.name}"
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_service" "notes_todo_service" {
  name            = "notes-todo-service"
  cluster         = "${aws_ecs_cluster.notes_todo_cluster.id}"
  task_definition = "${aws_ecs_task_definition.notes_todo_task.arn}"
  launch_type     = "FARGATE"
  desired_count   = 1
  force_new_deployment = true
  load_balancer {
    target_group_arn = "${aws_lb_target_group.notes_todo_target_group.arn}" # Referencing our target group
    container_name   = "${aws_ecs_task_definition.notes_todo_task.family}"
    container_port   = 3000 # Specifying the container port
  }

  network_configuration {
    subnets          = aws_subnet.notes_todo_subnets[*].id
    assign_public_ip = true # Providing our containers with public IPs
    security_groups  = ["${aws_security_group.service_security_group.id}"]
  }
}

resource "aws_alb" "notes_todo_load_balancer" {
  name               = "notes-todo-lb-tf"
  internal = false
  load_balancer_type = "application"
  subnets = aws_subnet.notes_todo_subnets[*].id
  # Referencing the security group
  security_groups = ["${aws_security_group.notes_todo_lb_security_groups.id}"]
}

# Creating a security group for the load balancer:
resource "aws_security_group" "notes_todo_lb_security_groups" {
  name        = "notes-todo-lb-sg"
  description = "Security group for the load balancer"
  vpc_id      = aws_vpc.notes_todo_vpc.id

  ingress {
    from_port   = 80 # Allowing traffic in from port 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Allowing traffic in from all sources
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0 # Allowing any incoming port
    to_port     = 0 # Allowing any outgoing port
    protocol    = "-1" # Allowing any outgoing protocol 
    cidr_blocks = ["0.0.0.0/0"] # Allowing traffic out to all IP addresses
  }
}

resource "aws_lb_target_group" "notes_todo_target_group" {
  name        = "target-group"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = "${aws_vpc.notes_todo_vpc.id}"
  health_check {
    matcher = "200,301,302"
    path = "/api/v1/note/all"
  }
}

resource "aws_lb_listener" "https_listener" {
  load_balancer_arn = aws_alb.notes_todo_load_balancer.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.notes_todo_target_group.arn
  }

  certificate_arn = aws_acm_certificate.notes_todo_certificate.arn
}

resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_alb.notes_todo_load_balancer.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "redirect"

    redirect {
        port = "443"
        protocol = "HTTPS"
        status_code = "HTTP_301"
    }    
    
  }
}


# resource "aws_lb_listener" "listener" {
#   load_balancer_arn = "${aws_alb.notes_todo_load_balancer.arn}" # Referencing our load balancer
#   port              = "80"
#   protocol          = "HTTP"
#   default_action {
#     type             = "forward"
#     target_group_arn = "${aws_lb_target_group.notes_todo_target_group.arn}" # Referencing our tagrte group
#   }
# }


resource "aws_security_group" "service_security_group" {
  name        = "service-security-group"
  description = "Security group for service"
  vpc_id      = aws_vpc.notes_todo_vpc.id

  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    # Only allowing traffic in from the load balancer security group
    security_groups = ["${aws_security_group.notes_todo_lb_security_groups.id}"]
  }

  egress {
    from_port   = 0 # Allowing any incoming port
    to_port     = 0 # Allowing any outgoing port
    protocol    = "-1" # Allowing any outgoing protocol 
    cidr_blocks = ["0.0.0.0/0"] # Allowing traffic out to all IP addresses
  }
}

resource "aws_route53_record" "notes_todo_record" {
  zone_id = var.hosted_zone
  name    = var.subdomain_name
  type    = "A"
  alias {
    name                   = aws_alb.notes_todo_load_balancer.dns_name
    zone_id                = aws_alb.notes_todo_load_balancer.zone_id
    evaluate_target_health = false
  }
}

resource "aws_acm_certificate" "notes_todo_certificate" {
  domain_name       = "${var.subdomain_name}.${var.domain_name}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "certificate_validation" {
  zone_id = var.hosted_zone
  name    = element(aws_acm_certificate.notes_todo_certificate.domain_validation_options[*].resource_record_name, 0)
  type    = element(aws_acm_certificate.notes_todo_certificate.domain_validation_options[*].resource_record_type, 0)
  ttl     = 60
  records = aws_acm_certificate.notes_todo_certificate.domain_validation_options[*].resource_record_value
}

resource "aws_acm_certificate_validation" "notes_todo_certificate_validation" {
  certificate_arn         = aws_acm_certificate.notes_todo_certificate.arn
  validation_record_fqdns = [aws_route53_record.certificate_validation.fqdn]
}

resource "aws_cloudwatch_log_group" "notes_todo_log_group" {
  name              = "/ecs/notes-todo"
  retention_in_days = 30
}

# output "url" {
#   value = aws_lb.notes_todo_lb.dns_name
# }