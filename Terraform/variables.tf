variable "sql_admin_password" {
  description = "Contrasena del administrador de Azure SQL"
  type        = string
  sensitive   = true
}
variable "sql_client_ip" {
  description = "IP publica autorizada para conectarse a Azure SQL"
  type        = string
}