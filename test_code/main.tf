
terraform { 
  cloud { 
    hostname = "tfe5.munnep.com" 
    organization = "test" 

    workspaces { 
      name = "test" 
    } 
  } 
}

resource "null_resource" "name" {
  
}