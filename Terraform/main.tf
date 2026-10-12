terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }
}


provider "azurerm" {
  features {}
}

locals {
  # Incrementar conscientemente para recargar ERP: el primer script elimina tablas.
  erp_seed_version = "1"

  raw_files = setunion(
    fileset(path.module, "datos_csv/*.csv"),
    fileset(path.module, "datos_xls/*.xlsx"),
  )

  erp_sql_scripts = [
    "01_crear_esquema.sql",
    "02_catalogos.sql",
    "03_datos_2024.sql",
    "04_datos_2025.sql",
  ]
}

# 1. Grupo de recursos y almacenamiento en Brazil South.
resource "azurerm_resource_group" "rg" {
  name     = "gr-ucb-transporte"
  location = "brazilsouth"
}

resource "azurerm_storage_account" "storage" {
  name                            = "saucbtransporte70645646"
  resource_group_name             = azurerm_resource_group.rg.name
  location                        = azurerm_resource_group.rg.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  is_hns_enabled                  = true
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"
}

# Lectura anonima de blobs individuales, segun el escenario documentado.
resource "azurerm_storage_container" "raw" {
  name                  = "raw"
  storage_account_name  = azurerm_storage_account.storage.name
  container_access_type = "private"
}

# Conserva la carpeta de origen en el nombre del blob y detecta cambios de contenido.
resource "azurerm_storage_blob" "raw_files" {
  for_each = local.raw_files

  name                   = each.value
  storage_account_name   = azurerm_storage_account.storage.name
  storage_container_name = azurerm_storage_container.raw.name
  type                   = "Block"
  source                 = "${path.module}/${each.value}"
  content_md5            = filemd5("${path.module}/${each.value}")
  content_type           = length(regexall("\\.csv$", lower(each.value))) > 0 ? "text/csv" : "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
}

# 2. Servidor y bases Azure SQL en Brazil South.
resource "azurerm_mssql_server" "sql_server" {
  name                         = "sql-ucb-server-transporte-7036465645"
  resource_group_name          = azurerm_resource_group.rg.name
  location                     = azurerm_resource_group.rg.location
  version                      = "12.0"
  administrator_login          = "franklin"
  administrator_login_password = var.sql_admin_password
  minimum_tls_version          = "1.2"

}

# Acceso desde cualquier IPv4, como en la configuracion original, para sqlcmd local.
resource "azurerm_mssql_firewall_rule" "allow_azure_services" {
  name             = "AllowMyComputer"
  server_id        = azurerm_mssql_server.sql_server.id
  start_ip_address = var.sql_client_ip
  end_ip_address   = var.sql_client_ip
}

# Habilita explicitamente la conexion desde servicios alojados en Azure.
resource "azurerm_mssql_firewall_rule" "allow_azure_services_explicit" {
  name             = "AllowAzureServices"
  server_id        = azurerm_mssql_server.sql_server.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "azurerm_mssql_database" "db" {
  for_each = toset(["erp_transporte_db", "dw_transporte"])

  name                        = each.value
  server_id                   = azurerm_mssql_server.sql_server.id
  collation                   = "SQL_Latin1_General_CP1_CI_AS"
  sku_name                    = "GP_S_Gen5_1"
  max_size_gb                 = 32
  min_capacity                = 0.5
  auto_pause_delay_in_minutes = 60
}

# 3. Carga inicial de ERP: esquema, catalogos, datos 2024 y datos 2025.
# El primer script elimina tablas existentes. Para repetir la carga, incrementar
# erp_seed_version conscientemente antes de ejecutar terraform apply.
resource "terraform_data" "erp_schema" {
  triggers_replace = [
    azurerm_mssql_database.db["erp_transporte_db"].id,
    local.erp_seed_version,
  ]

  depends_on = [
    azurerm_mssql_firewall_rule.allow_azure_services,
  ]

  lifecycle {
    precondition {
      condition     = alltrue([for script in local.erp_sql_scripts : fileexists("${path.module}/sql/${script}")])
      error_message = "Deben existir los cuatro scripts SQL de carga ERP en sql/."
    }
  }

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-NoProfile", "-NonInteractive", "-Command"]

    environment = {
      SQL_SERVER      = azurerm_mssql_server.sql_server.fully_qualified_domain_name
      SQL_DATABASE    = azurerm_mssql_database.db["erp_transporte_db"].name
      SQL_USER        = azurerm_mssql_server.sql_server.administrator_login
      SQLCMDPASSWORD  = azurerm_mssql_server.sql_server.administrator_login_password
      SQL_SCRIPT_DIR  = abspath("${path.module}/sql")
      SQL_SCRIPT_LIST = join(";", local.erp_sql_scripts)
    }

    command = <<-POWERSHELL
      $ErrorActionPreference = "Stop"
      $sqlcmdCommand = Get-Command sqlcmd -ErrorAction SilentlyContinue | Select-Object -First 1
      $sqlcmd = if ($sqlcmdCommand) { $sqlcmdCommand.Source } elseif (Test-Path -LiteralPath "C:\Program Files\SqlCmd\sqlcmd.exe") { "C:\Program Files\SqlCmd\sqlcmd.exe" } else { throw "Instale sqlcmd antes de ejecutar Terraform." }
      $commonArgs = @("-S", $env:SQL_SERVER, "-d", $env:SQL_DATABASE, "-U", $env:SQL_USER, "-b", "-r", "1", "-l", "30")

      $connected = $false
      for ($attempt = 1; $attempt -le 12; $attempt++) {
        & $sqlcmd @commonArgs -Q "SET NOCOUNT ON; SELECT 1;" *> $null
        if ($LASTEXITCODE -eq 0) {
          $connected = $true
          break
        }
        Start-Sleep -Seconds 10
      }
      if (-not $connected) {
        throw "No se pudo conectar a la base ERP despues de crearla y configurar el firewall."
      }

      foreach ($scriptName in $env:SQL_SCRIPT_LIST.Split(";")) {
        $scriptPath = Join-Path $env:SQL_SCRIPT_DIR $scriptName
        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
          throw "No existe el script SQL: $scriptPath"
        }
        Write-Host "Ejecutando $scriptName en $env:SQL_DATABASE"
        & $sqlcmd @commonArgs -i $scriptPath
        if ($LASTEXITCODE -ne 0) {
          throw "Fallo $scriptName (codigo $LASTEXITCODE)."
        }
      }
    POWERSHELL
  }
}

# 4. Factoria de integracion en East US.
resource "azurerm_data_factory" "adf" {
  name                = "adf-ucb-transporte-us-7053456345"
  resource_group_name = azurerm_resource_group.rg.name
  location            = "eastus"
}
