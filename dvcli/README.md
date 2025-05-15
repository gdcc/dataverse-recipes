<p align="center">  
# Dataverse CLI Recipes 🦀
</p>

The Dataverse Command Line Interface (DVCLI) is a tool that allows you to manage your Dataverse instance from the command line. It is based on the [Rust-Dataverse crate](https://github.com/gdcc/rust-dataverse) which implements a subset of the Dataverse REST API. This collection of recipes demonstrates how to use DVCLI to manage your Dataverse instance. The following concepts are covered:

- Dataset/Collection Management
- File Management
- Direct Uploads
- Search and Discovery

## 📦 Installation

DVCLI is a Rust application that can be installed using Cargo. Currently, DVCLI is in the early stages of development and is not yet available on crates.io, but can be installed directly from the GitHub repository.

```bash
cargo install --git https://github.com/gdcc/rust-dataverse.git --bin dvcli
```

> Please note, that Rust needs to be installed to compile DVCLI. You can use [rustup](https://rustup.rs/) to install Rust. In the future we will provide pre-compiled binaries via brew and other package managers.

## 📚 Available Recipes

We recommend first covering the `authentication.sh` recipe to get an idea of how to authenticate to your Dataverse instance, because all other recipes make use of the authenticated session. Also, if you want to verify the installation, you can run the `hello_world.sh` recipe to fetch the current version of Demo-Dataverse aka the unofficial "Hello, World!" of Dataverse.

- [Authentication](./authentication.sh)
- [Hello World](./hello_world.sh)
- [Dataset Management](./datasets)
  - [Create, upload and publish a dataset](./datasets/create_upload_publish_dataset.sh)
  - [Fetch Dataset Metadata](./datasets/dataset_metadata.sh)
  - [Edit Dataset Metadata](./datasets/edit_dataset.sh)
  - [Link a Dataset](./datasets/link.sh)
  - [Direct Upload](./datasets/direct_upload.sh)
  - [Directory Upload](./datasets/directory_upload.sh)
  - [Download a Dataset](./datasets/download.sh)
  - [Remote Uploads](./datasets/remote_upload.sh)
  - [Dataset Locks](./datasets/locks.sh)
  - [Review Management](./datasets/review.sh)
- [Collection Management](./collections)
  - [Create, publish and delete a Collection](./collections/create_publish_delete_collection.sh)
- [File Management](./files)
  - [Replace a File](./files/replace_file.sh)
- [Search and Discovery](./search)
  - [Query Demo Dataverse](./search/search_demo_dv.sh)
- [Administration](./admin)
  - [Managing collection storage drivers](./admin/storage_drivers.sh)
