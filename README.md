<h1 align="center">🍳 Dataverse Recipes</h1>

<p align="center">A collection of code recipes and examples for interacting with Dataverse using different programming languages and tools. This repository serves as a practical resource for developers who need to integrate with Dataverse in their applications.</p>

## Why this repository?

This repository serves as a collection of examples and recipes for working with Dataverse, covering common topics such as:

- 🔌 How to interact with Dataverse APIs
- 🔄 Common integration patterns 
- ✅ Best practices for different programming languages
- 💡 Helpful solutions for typical use cases

## Repository Structure

The repository is organized by programming language and tool:

- `python/`: 🐍 Python recipes
- `shell/`: 🐚 Shell recipes
- `rust/`: 🦀 Rust recipes
- `dvcli/`: 🛠️ DVCLI recipes


Each language directory contains specific recipes organized by functionality or use case.

## 📚 Available Recipes

In the following sections, you can find a list of available recipes for each language:

### Python 🐍

- [Create datasets from Excel files](python/create_datasets_from_excel) 📊
- [Download Croissant from draft dataset](python/download_draft_croissant)
- [Create Croissant from the client side](python/create_croissant_client_side)

### Shell 🐚

- [Upload files using S3 direct upload](shell/s3_direct_upload)
- [Download files from a dataset](shell/download)
- [Upgrade Dataverse](shell/upgrades)
- [Testing](shell/testing)

## 🤝 Contributing

We welcome contributions! To add a new recipe:

1. Choose the appropriate language directory for your recipe 📂
2. Create a new directory for your specific recipe ➕
3. Include the following files:
   - `README.md` with:
     - Description of the recipe 📝
     - Prerequisites ✔️
     - Installation instructions 🔧
     - Usage examples 💻
     - Dependencies 📦
   - Source code files 👨‍💻
   - `requirements.txt` (for Python) or equivalent dependency file 📋
   - Example configuration files if needed ⚙️

4. Submit your contribution via a Pull Request 🚀

### ✨ Guidelines

- Keep recipes focused and well-documented 📖
- Include error handling and best practices 🛡️
- Test your code before submitting ✅
- Update the main README if adding new categories 📝
- Follow the existing directory structure 🏗️
- Suggest a way to get in touch

### Naming conventions

- File names should be in lowercase and use underscores to separate words (e.g. `create_dataset.py`).
- Directory names should be in lowercase and use underscores to separate words (e.g. `create_dataset`).

**Note:** If a language convention requires it, use camel/pascal case, but make sure to align with the existing naming conventions. Exceptions are:

- JavaScript: Use camel/kebab case (e.g. `create-dataset.js` or `createDataset.js`).
- Java: Use camel case (e.g. `CreateDataset.java`).

## 💬 Support

For issues and questions, please open an issue in this repository or discuss on [Zulip](https://dataverse.zulipchat.com/#narrow/channel/375707-community/topic/recipes/near/503105735)! 🐙
