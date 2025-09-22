# Dataverse Metadata Block Recipes

This directory contains JavaScript/TypeScript recipes for working with Dataverse metadata blocks. These tools help you interact with, analyze, and manage metadata schemas across different Dataverse instances.

## Getting Started

Install dependencies:

```bash
npm install
```

## Available Recipes

### 1. List Metadata blocks (`list.ts`)

Retrieves and displays all metadata blocks from a Dataverse instance.

**Usage:**

```bash
# Predefined environments
npm run list:demo        # Demo Dataverse instance

# With additional options
npm run list:demo -- --api-token your-token-here
npm run list:demo -- --output metadata-blocks.json
npm run list:demo -- --api-token your-token --output local-blocks.json

# Direct usage with custom URL
npx tsx list.ts --base-url https://your-dataverse.org/api/v1
```

**Options:**

- `-b, --base-url <url>`: Base URL for the Dataverse API (required)
- `-a, --api-token <token>`: API token for authentication (optional)
- `-o, --output <file>`: Save output to file instead of console (optional)
- `-h, --help`: Show help information

## Requirements

- Node.js `>= 20.0.0`
- TypeScript
- Access to a Dataverse instance