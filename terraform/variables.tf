variable "project_id" {
  type    = string
  default = "hybridmod"
}

variable "region" {
  type    = string
  default = "asia-south1"
}

variable "zone" {
  type    = string
  default = "asia-south1-a"
}

variable "backup_bucket" {
  type    = string
  default = "hybridmod-db-backups_rt"
}
