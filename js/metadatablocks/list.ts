/**
 * Dataverse Metadata Blocks Listing Tool
 * 
 * This script retrieves and displays all metadata blocks from a Dataverse instance.
 * It can output the results to the console or save them to a JSON file.
 * 
 * Usage:
 *   npx tsx list.ts -b https://demo.dataverse.org/api/v1
 *   npx tsx list.ts -b https://demo.dataverse.org/api/v1 -a your-api-token
 *   npx tsx list.ts -b https://demo.dataverse.org/api/v1 -o metadata-blocks.json
 */

import { ApiConfig, getAllMetadataBlocks, MetadataBlock, } from '@iqss/dataverse-client-javascript'
import { DataverseApiAuthMechanism } from '@iqss/dataverse-client-javascript/dist/core/infra/repositories/ApiConfig';
import { Command } from 'commander';
import fs from 'fs';

// Initialize the command line interface
const program = new Command();

program
    .name('list')
    .description('List all metadata blocks from a Dataverse instance')
    .version('1.0.0')
    .requiredOption('-b, --base-url <url>', 'Base URL for the Dataverse API')
    .option('-a, --api-token <token>', 'API token for authentication')
    .option('-o, --output <file>', 'Output file for the metadata blocks (optional, otherwise prints to console)');

// Parse command line arguments
program.parse();

// Extract options from parsed arguments
const options = program.opts();
const baseUrl = options.baseUrl;
const apiToken = options.apiToken;
const output = options.output;

// Initialize the Dataverse API configuration
// Uses API key authentication if token is provided, otherwise uses anonymous access
ApiConfig.init(
    baseUrl,
    DataverseApiAuthMechanism.API_KEY,
    apiToken
)

// Fetch all metadata blocks from the configured Dataverse instance
getAllMetadataBlocks.execute().then((metadataBlocks: MetadataBlock[]) => {
    if (output) {
        // Save metadata blocks to specified file as formatted JSON
        fs.writeFileSync(output, JSON.stringify(metadataBlocks, null, 2));
        console.log(`Metadata blocks saved to ${output}`);
    } else {
        // Print metadata blocks to console
        console.log(metadataBlocks);
    }
}).catch((error) => {
    // Handle any errors that occur during the API call
    console.error('Error fetching metadata blocks:', error);
    process.exit(1);
});
