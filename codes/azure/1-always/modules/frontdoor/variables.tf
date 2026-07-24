variable "environment" {
  description = "Environment name"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group name"
  type        = string
}

variable "azure_blob_fqdn" {
  description = "Azure Blob Storage static website FQDN"
  type        = string
}

variable "azure_appgw_ip" {
  description = "Azure Application Gateway Public IP"
  type        = string
}

variable "backend_mode" {
  description = "Active Front Door backend: maintenance or azure_service"
  type        = string
  default     = "maintenance"

  validation {
    condition     = contains(["maintenance", "azure_service"], var.backend_mode)
    error_message = "backend_mode must be maintenance or azure_service."
  }
}

variable "custom_domain" {
  description = "Custom domain name (e.g., blueisthenewblack.store)"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
