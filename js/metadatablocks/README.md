# Dataverse Metadatablocks Recipes

This directory contains JavaScript/TypeScript recipes for working with Dataverse metadatablocks. These tools help you interact with, analyze, and manage metadata schemas across different Dataverse instances.

## Available Recipes

### 1. List Metadatablocks (`list.ts`)

Retrieves and displays all metadata blocks from a Dataverse instance.

**Usage:**

```bash
# Predefined environments
npm run list:demo        # Demo Dataverse instance
npm run list:harvard     # Harvard Dataverse

# With additional options
npm run list:demo -- --api-token your-token-here
npm run list:demo -- --output metadata-blocks.json
npm run list:demo -- --api-token your-token --output harvard-blocks.json

# Direct usage with custom URL
npm run list -- --base-url https://your-dataverse.org/api/v1
```

**Options:**

- `-b, --base-url <url>`: Base URL for the Dataverse API (required)
- `-a, --api-token <token>`: API token for authentication (optional)
- `-o, --output <file>`: Save output to file instead of console (optional)
- `-h, --help`: Show help information

## Getting Started

1. Install dependencies:

   ```bash
   npm install
   ```

2. Run any of the available scripts:

   ```bash
   npm run list:demo
   ```

## Requirements

- Node.js
- TypeScript
- Access to a Dataverse instance
