terraform {
  backend "gcs" {
    bucket  = "tf-state-tipo168"
    prefix  = "terraform/state"
  }
}
