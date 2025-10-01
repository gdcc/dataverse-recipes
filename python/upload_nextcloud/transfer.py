#!/usr/bin/env python3
"""
Nextcloud to Dataverse Transfer Tool

This script downloads files from a Nextcloud link share and uploads them to a Dataverse dataset.
It handles file size limit adjustments, resumable downloads, and maintains a journal for progress tracking.
"""

import argparse
import humanize
import json
import logging
import os
import re
import requests
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from pyDataverse.api import NativeApi
from pyDataverse.models import Datafile
from urllib.parse import urljoin, urlparse

# Set up logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

class Transfer:
    def __init__(self, share_url, dataverse_url, api_token, dataset_doi, skip_existing=False,
                 subpath="", temp_dir=None, journal_file="transfer_journal.txt"):
        self.share_url = share_url
        self.largest_file_size = -1
        self.dataverse_url = dataverse_url
        self.api_token = api_token
        self.dataset_doi = dataset_doi
        self.subpath = subpath.strip('/')
        self.skip_existing = skip_existing
        self.temp_dir = temp_dir or tempfile.gettempdir()
        self.journal_file = journal_file
        self.native_api = NativeApi(dataverse_url, api_token)
        self.original_limit = None
        
        # Create temp directory if it doesn't exist
        os.makedirs(self.temp_dir, exist_ok=True)
        
        # Session for requests
        self.session = requests.Session()
    
    def get_webdav_url(self):
        """Convert public share URL to WebDAV URL"""
        parsed = urlparse(self.share_url)
        share_token = parsed.path.split('/')[-1]
        webdav_url = f"{parsed.scheme}://{parsed.netloc}/public.php/webdav"
        return webdav_url, share_token
    
    def list_files_recursive(self, path=""):
        """Recursively list all files in the Nextcloud share using WebDAV"""
        webdav_url, share_token = self.get_webdav_url()
        full_path = path
        if self.subpath:
            full_path = f"{self.subpath}/{path}".strip('/')
        
        propfind_url = urljoin(webdav_url + "/", full_path)
        
        # PROPFIND request to get directory contents
        headers = {'Depth': '1'}
        auth = (share_token, '')
        
        try:
            response = self.session.request('PROPFIND', propfind_url, auth=auth, headers=headers)
            response.raise_for_status()
        except requests.RequestException as e:
            logger.error(f"Failed to access Nextcloud share: {e}")
            sys.exit(1)
        
        # Parse WebDAV XML response
        files = []
        root = ET.fromstring(response.content)
        responses = root.findall('.//{DAV:}response')

        # Check if this is a single file share (only one response and it's a file)
        if len(responses) == 1:
            response_elem = responses[0]
            propstat = response_elem.find('.//{DAV:}propstat')
            if propstat is not None:
                prop = propstat.find('{DAV:}prop')
                if prop is not None:
                    resourcetype = prop.find('{DAV:}resourcetype')
                    is_directory = resourcetype.find('{DAV:}collection') is not None

                    if not is_directory:
                        # This is a single file share
                        href = response_elem.find('{DAV:}href').text
                        relative_path = href.replace('/public.php/webdav/', '').strip('/')

                        size_elem = prop.find('{DAV:}getcontentlength')
                        file_size = int(size_elem.text) if size_elem is not None else 0

                        # For single file shares, use just the filename
                        file_path = os.path.basename(relative_path) if relative_path else "shared_file"

                        files.append({
                            'path': file_path,
                            'size': file_size,
                            'full_path': relative_path
                        })

                        return files


        for response_elem in responses:
            href = response_elem.find('{DAV:}href').text
            # Remove webdav prefix and decode
            relative_path = href.replace('/public.php/webdav/', '').strip('/')
            
            # Skip the current directory itself
            if relative_path == full_path:
                continue
            
            # Get properties
            propstat = response_elem.find('.//{DAV:}propstat')
            if propstat is None:
                continue
                
            prop = propstat.find('{DAV:}prop')
            if prop is None:
                continue
            
            # Check if it's a file or directory
            resourcetype = prop.find('{DAV:}resourcetype')
            is_directory = resourcetype.find('{DAV:}collection') is not None
            
            if is_directory:
                # Recursively get files from subdirectory
                subdir_path = relative_path
                if self.subpath:
                    subdir_path = relative_path[len(self.subpath):].strip('/')
                files.extend(self.list_files_recursive(subdir_path))
            else:
                # It's a file
                size_elem = prop.find('{DAV:}getcontentlength')
                file_size = int(size_elem.text) if size_elem is not None else 0
                
                file_path = relative_path
                if self.subpath:
                    file_path = relative_path[len(self.subpath):].strip('/')
                
                files.append({
                    'path': file_path,
                    'size': file_size,
                    'full_path': relative_path
                })
        
        return files
    
    def read_journal(self):
        """Read the migration journal to get progress and original limit"""
        if not os.path.exists(self.journal_file):
            return {}
        
        journal = {}
        
        with open(self.journal_file, 'r') as f:
            lines = f.readlines()
        
        for line in lines:
            line = line.strip()
            if not line:
                continue
            parts = line.split(';', 1)
            if len(parts) == 2:
                status, path = parts
                journal[path] = status
        
        return journal

    def update_journal(self, file_path, status):
        """Update journal with file status"""
        journal = self.read_journal()
        journal[file_path] = status
        
        with open(self.journal_file, 'w') as f:
            for path, stat in journal.items():
                f.write(f"{stat};{path}\n")
    
    def download_file(self, file_info):
        """Download a single file from Nextcloud"""
        webdav_url, share_token = self.get_webdav_url()
        file_url = urljoin(webdav_url + "/", file_info['full_path'])
        
        # Local file path
        local_path = os.path.join(self.temp_dir, os.path.basename(file_info['path']))
        
        auth = (share_token, '')
        
        try:
            logger.info(f"Downloading {file_info['path']} ({file_info['size']} bytes)")
            response = self.session.get(file_url, auth=auth, stream=True)
            response.raise_for_status()
            
            with open(local_path, 'wb') as f:
                for chunk in response.iter_content(chunk_size=8192):
                    f.write(chunk)
            
            logger.info(f"Downloaded to {local_path}")
            return local_path
            
        except requests.RequestException as e:
            logger.error(f"Failed to download {file_info['path']}: {e}")
            sys.exit(1)
    
    def upload_direct(self, local_file_path, file_info):
        """Upload file directly to Dataverse using pyDataverse"""
        try:
            # Create datafile object
            df = Datafile()
            df.set({
                "pid": self.dataset_doi,
                "filename": os.path.basename(file_info['path']),
            })
            
            # Add directory information if file is in subdirectory
            if '/' in file_info['path']:
                directory_path = '/'.join(file_info['path'].split('/')[:-1])
                df.set({"directoryLabel": directory_path})
            
            # Upload file
            logger.info(f"Uploading {file_info['path']} to Dataverse dataset {self.dataset_doi}")
            response = self.native_api.upload_datafile(self.dataset_doi, local_file_path, df.json())
            
            if response.status_code == 200:
                logger.info(f"Successfully uploaded {file_info['path']}")
                return True
            else:
                # Check for file size limit error message
                if "exceeds the size limit of" in response.json().get('message', ''):
                    logger.error(f"Upload failed for {file_info['path']}.")
                    match = re.search(r"exceeds the size limit of (.+ [KMGTPE]?B)", response.text)
                    current_limit = match.group(1)
                    self.print_curl_command_for_admin(current_limit, self.largest_file_size)
                elif "file already exists" in response.json().get('message', '') and self.skip_existing:
                    logger.warning(f"File {file_info['path']} already exists in dataset, skipping upload as requested.")
                    return True
                else:
                    logger.error(f"Upload failed for {file_info['path']}: {response.status_code} - {response.text}")

                return False
                
        except Exception as e:
            logger.error(f"Upload failed for {file_info['path']}: {e}")
            return False
    
    def cleanup_temp_file(self, file_path):
        """Remove temporary downloaded file"""
        try:
            os.remove(file_path)
            logger.debug(f"Removed temporary file {file_path}")
        except OSError as e:
            logger.warning(f"Could not remove temporary file {file_path}: {e}")

    def print_curl_command_for_admin(self, current_limit, required_limit):
        """Print curl command for admin to increase upload limit"""
        msg = ""
        msg += "\n" + "="*80 + "\n"
        msg += "ADMIN ACTION REQUIRED\n"
        msg += "="*80 + "\n"
        msg += f"The largest file ({humanize.naturalsize(required_limit, binary=True)}) exceeds the current upload limit of {current_limit}.\n"
        msg += "Please run the following curl command as a Dataverse admin to temporarily increase the limit:\n"
        msg += f"""curl -X PUT "{self.dataverse_url}/api/v1/admin/settings/:MaxFileUploadSizeInBytes" -d "{required_limit + 1024*1024}"\n"""
        msg += "If you're the admin: note to add the ?unblock-key=... parameter when required.\n"
        msg += f"This will set the limit to {humanize.naturalsize(required_limit + 1024*1024, binary=True)} (largest file size + 1MB).\n"
        msg += "="*80 + "\n"
        logger.error(msg)


    def transfer(self):
        """Main migration process"""
        logger.info("Starting Nextcloud to Dataverse transfer")
        
        # Get list of all files
        logger.info("Scanning Nextcloud share for files...")
        files = self.list_files_recursive()
        
        if not files:
            logger.info("No files found in the share")
            return
        
        logger.info(f"Found {len(files)} files")
        for file in files:
            logger.debug(f"{file['full_path']} ({humanize.naturalsize(file['size'], binary=True)})")
        
        # Find largest file
        self.largest_file_size = max(file['size'] for file in files)
        logger.info(f"Largest file size: {self.largest_file_size} bytes ({humanize.naturalsize(self.largest_file_size, binary=True)})")

        # Read existing journal or create new one
        journal = self.read_journal()

        # Process each file
        for file_info in files:
            file_path = file_info['path']
            
            # Check journal status
            status = journal.get(file_path, '')
            
            if status == 'U':
                logger.info(f"Skipping {file_path} - already uploaded")
                continue
            
            local_file_path = None
            
            try:
                # Download if not already done
                if status != 'D':
                    local_file_path = self.download_file(file_info)
                    self.update_journal(file_path, 'D')
                else:
                    # File was downloaded before, find it
                    local_file_path = os.path.join(self.temp_dir, os.path.basename(file_path))
                    if not os.path.exists(local_file_path):
                        logger.warning(f"Previously downloaded file {local_file_path} not found, re-downloading")
                        local_file_path = self.download_file(file_info)
                        self.update_journal(file_path, 'D')
                
                # Upload file
                if self.upload_direct(local_file_path, file_info):
                    self.update_journal(file_path, 'U')
                    # Clean up temp file after successful upload
                    self.cleanup_temp_file(local_file_path)
                else:
                    logger.error(f"Upload failed for {file_path}")
                    sys.exit(1)
                    
            except Exception as e:
                logger.error(f"Error processing {file_path}: {e}")
                if local_file_path and os.path.exists(local_file_path):
                    self.cleanup_temp_file(local_file_path)
                sys.exit(1)

        logger.info("Transfer completed successfully!")
        logger.warning("\n" + "="*80 + "\n" +
                       "If changed, remember to restore the original upload limit now!\n" +
                       "="*80 + "\n")

def main():
    parser = argparse.ArgumentParser(description='Transfer files from Nextcloud link share to Dataverse')

    # Nextcloud arguments
    parser.add_argument('--share', required=False,
                       help='(Req.) Nextcloud public share URL (e.g., https://cloud.example.com/s/sHaReToKeN). Can be set as env var NEXTCLOUD_SHARE_URL.')
    parser.add_argument('--subpath', default='',
                        help='(Opt.) Subpath within the Nextcloud share to start the file tree traversal from')

    # Dataverse arguments
    parser.add_argument('--instance', required=False,
                       help='(Req.) Dataverse instance URL (e.g., https://demo.dataverse.org). Can be set as env var DATAVERSE_URL.')
    parser.add_argument('--api-token', required=False,
                       help='(Req.) Dataverse API Token. Superadmin or other with permissions for dataset. Can be set as env var DATAVERSE_API_TOKEN.')
    parser.add_argument('--dataset-doi', required=False,
                       help='(Req.) Target dataset DOI (e.g., doi:10.1234/5678). Can be set as env var DATASET_DOI.')
    parser.add_argument('--skip-existing', required=False, action='store_true',
                       help='(Opt.) Skip files that have already been uploaded to the dataset (default: exit with error)')

    # Other arguments
    parser.add_argument('--temp-dir',
                       help='Temporary directory for downloads (default: system temp)')
    parser.add_argument('--journal-file', default='transfer_journal.txt',
                       help='Journal file to track progress (default: transfer_journal.txt)')
    parser.add_argument('--verbose', action='store_true',
                       help='Enable verbose logging output')
    parser.add_argument('--env-file', default='.env',
                       help='Path to .env file (default: .env in current directory)')

    args = parser.parse_args()

    # Set logging level based on verbose flag
    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    # Load environment from .env file if present
    if os.path.exists(args.env_file):
        with open(args.env_file) as f:
            for line in f:
                if line.strip() and not line.startswith('#'):
                    key, value = line.strip().split('=', 1)
                    os.environ[key] = value

    # Check for environment variables as fallback 
    share_url = args.share or os.getenv('NEXTCLOUD_SHARE_URL')
    dataverse_url = args.instance or os.getenv('DATAVERSE_URL')
    api_token = args.api_token or os.getenv('DATAVERSE_API_TOKEN')
    dataset_doi = args.dataset_doi or os.getenv('DATASET_DOI')

    # Validate required parameters
    if not all([share_url, dataverse_url, api_token, dataset_doi]):
        logger.error("Missing required parameters. Provide via command line or environment variables.")
        sys.exit(1)
    
    # Create migrator and run
    migrator = Transfer(
        share_url=share_url,
        dataverse_url=dataverse_url,
        api_token=api_token,
        dataset_doi=dataset_doi,
        subpath=args.subpath,
        skip_existing=args.skip_existing,
        temp_dir=args.temp_dir,
        journal_file=args.journal_file
    )
    
    migrator.transfer()

if __name__ == '__main__':
    main()
