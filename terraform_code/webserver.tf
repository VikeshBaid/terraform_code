provider "aws" {
  region                  = "ap-south-1"
  shared_credentials_file = "$HOME/.aws/credentials"
}

# generates key_pair
resource "tls_private_key" "this" {
  algorithm = "RSA"
  rsa_bits = 2048
}

# public key and key name
module "key_pair" {
  source = "terraform-aws-modules/key-pair/aws"
  key_name = "deployer1_key"
  public_key = tls_private_key.this.public_key_openssh
}


# default vpc used
data "aws_vpc" "default" {
 default = true
}

# security group for instance
resource "aws_security_group" "ssh-and-http" {
  name = "web-server1"
  description = "allowing inbound requests"
  vpc_id = data.aws_vpc.default.id


  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# instance creation
resource "aws_instance" "webserver" {
  depends_on = [
    tls_private_key.this,
    aws_security_group.ssh-and-http
  ]
  ami = "ami-0447a12f28fddb066"
  instance_type = "t2.micro"
  key_name = "deployer1_key"
  security_groups = [aws_security_group.ssh-and-http.name]

  tags = {
    Name = "task_one1"
  }
}

resource "null_resource" "instance_config" {
  depends_on = [
    aws_instance.webserver
  ]

  connection {
    type = "ssh"
    user = "ec2-user"
    private_key = tls_private_key.this.private_key_pem
    host = aws_instance.webserver.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "sudo yum install httpd php git -y",
      "sudo systemctl restart httpd",
      "sudo systemctl enable httpd",
    ]
  }
}

# Creating external volume for data to store in persistant storage
resource "aws_ebs_volume" "ebs_vlm" {
  availability_zone = aws_instance.webserver.availability_zone
  size = 1
  tags = {
    Name = "ws_data_volume1"
  }
}


# attaching that persistant storage to instance
resource "aws_volume_attachment" "ws_attach_volume" {
  depends_on = [
    aws_ebs_volume.ebs_vlm,
    aws_instance.webserver
  ]

  device_name = "/dev/sdf"
  volume_id = aws_ebs_volume.ebs_vlm.id
  instance_id = aws_instance.webserver.id
  force_detach = true
}

# null resource to run commands on aws_instance
# setup connection to instance using connection
# run command to format and mount persistant storage
resource "null_resource" "remote_command_1" {
  depends_on = [
    aws_volume_attachment.ws_attach_volume
  ]

  connection  {
    type = "ssh"
    user = "ec2-user"
    private_key = tls_private_key.this.private_key_pem
    host = aws_instance.webserver.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mkfs.ext4 /dev/xvdf",
      "sudo mount /dev/xvdf /var/www/html",
      "sudo rm -rf /var/www/html/*",
      "sudo git clone https://github.com/VikeshBaid/multicloud.git /var/www/html/"
    ]
  }
}


# Creating s3 bucket
resource "aws_s3_bucket" "images" {
  depends_on = [
    aws_volume_attachment.ws_attach_volume
  ]
  bucket = "image-storage-tf1"
  acl = "public-read"

  tags = {
    Name = "image-bucket"
  }
}

# cloning repository on local system to get images
resource "null_resource" "clone_image"{
  provisioner "local-exec" {
   command = "git clone https://github.com/VikeshBaid/images.git images"
  }

  provisioner "local-exec" {
    when = destroy
    command = "rm -rf images"
  }
}

# s3 uploading object into bucket
resource "aws_s3_bucket_object" "object" {
  depends_on = [
    aws_s3_bucket.images,
    null_resource.clone_image
  ]

  bucket = aws_s3_bucket.images.id
  key    = "terraform_image.jpg"
  content_type = "image/jpg"
  acl = "public-read"
  source = "images/Terraform-main-image.jpg"
}


# origin access id
resource "aws_cloudfront_origin_access_identity" "access" {
  comment = "used by cloudfront to access origin"
}


# creating cloudfront for s3 bucket object
resource "aws_cloudfront_distribution" "s3_distribution" {

  depends_on = [
    aws_instance.webserver,
    aws_s3_bucket_object.object,
    aws_cloudfront_origin_access_identity.access
  ]

  origin {
    domain_name = aws_s3_bucket.images.bucket_domain_name
    origin_id   = "S3-${aws_s3_bucket.images.id}"

    s3_origin_config {
       origin_access_identity = aws_cloudfront_origin_access_identity.access.cloudfront_access_identity_path
    }
  }


  enabled = true
  is_ipv6_enabled = true

  default_cache_behavior {
    allowed_methods = ["GET", "HEAD"]
    cached_methods = ["GET", "HEAD"]
    target_origin_id = "S3-${aws_s3_bucket.images.id}"

  forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

  viewer_protocol_policy = "allow-all"
  min_ttl = 0
  default_ttl = 3600
  max_ttl = 86400

  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}


resource "null_resource" "entry_index_php" {
  depends_on = [
    aws_cloudfront_distribution.s3_distribution
  ]

  connection {
   type = "ssh"
   user = "ec2-user"
   private_key = tls_private_key.this.private_key_pem
   host = aws_instance.webserver.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "sudo su << EOF",
      "echo \"<html>\" >> /var/www/html/index.php",
      "echo \"<img src='http://${aws_cloudfront_distribution.s3_distribution.domain_name}/${aws_s3_bucket_object.object.key}'>\" >> /var/www/html/index.php",
      "echo \"</html>\" >> /var/www/html/index.php",
      "EOF"
    ]
  }
}


output "cfront" {
  value = aws_cloudfront_distribution.s3_distribution.domain_name
}


output "Public_IP_of_Ec2" {
  value = aws_instance.webserver.public_ip
}

# launch the server using Terraform
resource "null_resource" "launch" {
  depends_on = [
    aws_cloudfront_distribution.s3_distribution
  ]

  provisioner "local-exec" {
    command = "firefox ${aws_instance.webserver.public_ip}"
  }
}
