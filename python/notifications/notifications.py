#!/usr/bin/env python3
import os
import sys
import urllib.request as urlrequest
import json
import argparse
import re
from datetime import datetime


def main():
    parser = argparse.ArgumentParser(
        description="Display your notifications from a Dataverse installation."
    )
    parser.add_argument(
        "-b",
        "--base_url",
        help="The base URL of the Dataverse installation such as https://demo.dataverse.org",
        type=str,
        required=True,
    )
    parser.add_argument(
        "-a",
        "--api_token",
        help="The API token to use for authentication. If not provided, it will be read from the API_TOKEN environment variable.",
        type=str,
        default=None,
    )
    parser.add_argument(
        "-v",
        "--verbose",
        help="Show more output.",
        action="store_true",
    )
    parser.add_argument(
        "-u",
        "--ugly",
        help="Don't pretty-print the JSON output.",
        action="store_true",
    )
    args = parser.parse_args()

    # Check if API token is provided via argument or environment variable
    if not args.api_token:
        args.api_token = os.getenv("API_TOKEN")
        if not args.api_token:
            print(
                "Error: API token is required. Provide it via the --api_token argument or the API_TOKEN environment variable."
            )
            sys.exit(1)

    url = construct_url(args.base_url)

    if args.verbose:
        print(f"Fetching notifications from {url}")

    json_raw = fetch_notifications(url, args.api_token)
    json_pretty = json.dumps(json_raw, indent=2)
    json_final = ""

    if args.ugly:
        json_final = json_raw
    else:
        json_pretty = json.dumps(json_raw, indent=2)
        json_final = json_pretty

    if args.verbose:
        print(json_final)

    for notification in json_raw["data"]["notifications"]:
        # print(notification)
        # print(notification["type"])
        message = "The dataverse, dataset, or file for this notification has been deleted."
        if "messageText" in notification:
            print(notification)
            type = notification["type"]
            message = notification["messageText"]
            print(f"{message} {notification['sentTimestamp']}")
            print()
            # message = "Philip Durbin Dataverse was created in Demo Dataverse . To learn more about what you can do with your dataverse, check out the User Guide."
            # print(f"{message} {notification['sentTimestamp']}")
            print()
            # message = """<div class="notification-item-cell">
            #                                         <span class="icon-dataverse text-icon-inline text-muted"></span>
            #                                                 <a href="/dataverse/pdurbin" title="Philip Durbin Dataverse">Philip Durbin Dataverse</a> was created in 
            #                                                 <a href="/dataverse/demo" title="Demo Dataverse">Demo Dataverse</a> . To learn more about what you can do with your dataverse, check out the 
            #                                                 <a href="https://guides.dataverse.org/en/6.7/user/dataverse-management.html" title="Dataverse Management - Dataverse User Guide" target="_blank">User Guide</a>. <span class="text-muted small">Sep 13, 2015, 6:31:54 PM EDT</span>
            #                             </div>"""
            # message = """<a href="/dataverse/pdurbin" title="Philip Durbin Dataverse">Philip Durbin Dataverse</a> was created in <a href="/dataverse/demo" title="Demo Dataverse">Demo Dataverse</a> . To learn more about what you can do with your dataverse, check out the <a href="https://guides.dataverse.org/en/6.7/user/dataverse-management.html" title="Dataverse Management - Dataverse User Guide" target="_blank">User Guide</a>.\
# """
            if type == "ASSIGNROLE":
                role = "FIXME---Admin/Dataverse + Dataset Creator---FIXME"
                message = f'You have been granted the {role} role for <a href="/dataverse/root" title="Root">Root</a>.'
                print(f"{message} {notification['sentTimestamp']}")
                print()
            elif type == "SUBMITTEDDS":
#                 message = """\
# <a href="/dataset.xhtml?persistentId=doi:10.5072/FK2/Y733KJ&amp;version=DRAFT&amp;faces-redirect=true" title="Darwin's Finches">Darwin's Finches</a> was submitted for review to be published in \
# <a href="/dataverse/dv085f7b38" title="dv085f7b38">dv085f7b38</a>. Don't forget to publish it or send it back to the contributor, \
# usercc149b2d usercc149b2d (usercc149b2d@mailinator.com)!\
# """
#notification.wasSubmittedForReview={0} was submitted for review to be published in {1}. Don''t forget to publish it or send it back to the contributor, {2} ({3})\!

                dataset_title = notification["datasetTitle"]
                requestor_first_name = notification["requestorFirstName"]
                requestor_last_name = notification["requestorLastName"]
                requestor_email = notification["requestorEmail"]
                dataset_relative_url_to_root_with_spa = notification["datasetRelativeUrlToRootWithSpa"]
                parent_collection_name = notification["parentCollectionName"]
                parent_collection_relative_url_to_root_with_spa = notification["parentCollectionRelativeUrlToRootWithSpa"]
                # message = f'<a href="/dataset.xhtml?persistentId=doi:10.5072/FK2/Y733KJ&amp;version=DRAFT&amp;faces-redirect=true" title="Darwin\'s Finches">{dataset_name}</a> was submitted for review to be published in <a href="/dataverse/dv085f7b38" title="dv085f7b38">dv085f7b38</a>. Don\'t forget to publish it or send it back to the contributor, \
                message = f'<a href="{dataset_relative_url_to_root_with_spa}" title="{dataset_title}">{dataset_title}</a> was submitted for review to be published in <a href="{parent_collection_relative_url_to_root_with_spa}" title="{parent_collection_name}">{parent_collection_name}</a>. Don\'t forget to publish it or send it back to the contributor, {requestor_first_name} {requestor_last_name} ({requestor_email})!'
                print(f"{message} {notification['sentTimestamp']}")
                print()
            elif type == "CREATEACC":
#                  message = """\
#Welcome to Root! Get started by adding or finding data. Have questions? Check out the 
#<a href="https://guides.dataverse.org/en/6.7/user/index.html" title="Root User Guide" target="_blank">User Guide</a>. Want to test out Dataverse features? Use our 
#<a href="https://demo.dataverse.org">Demo Site</a>. Also, check for your welcome email to verify your address.
# """
                installation_brand_name = notification["installationBrandName"]
                user_guide_url = notification["userGuideUrl"]
                message = f'Welcome to {installation_brand_name}! Get started by adding or finding data. Have questions? Check out the \
<a href="{user_guide_url}" title="User Guide" target="_blank">User Guide</a>. \
Want to test out Dataverse features? Use our <a href="https://demo.dataverse.org">Demo Site</a>. \
Also, check for your welcome email to verify your address.'
                print(f"{message} {notification['sentTimestamp']}")
                print()
            elif type == "REQUESTFILEACCESS":
                manage_file_permissions_relative_url_to_root_with_spa = notification["manageFilePermissionsRelativeUrlToRootWithSpa"]
                dataset_title = notification["datasetTitle"]
                requestor_first_name = notification["requestorFirstName"]
                requestor_last_name = notification["requestorLastName"]
                requestor_email = notification["requestorEmail"]
                message = f'File access requested for dataset: <a href="/permissions-manage-files.xhtml?id=110" title="{dataset_title}">{dataset_title}</a> was made by \
{requestor_first_name} {requestor_last_name} ({requestor_email}).'
                print(f"{message} {notification['sentTimestamp']}")
                print()
            elif type == "RETURNEDDS":
                message = """\
<a href="/dataset.xhtml?persistentId=doi:10.5072/FK2/DR0OKF&amp;version=DRAFT&amp;faces-redirect=true" title="newTitle">newTitle</a> was returned by the curator of \
<a href="/dataverse/dv9cab5a06" title="dv9cab5a06">dv9cab5a06</a>.
"""
                dataset_title = notification["datasetTitle"]
                dataset_relative_url_to_root_with_spa = notification["datasetRelativeUrlToRootWithSpa"]
                parent_collection_name = notification["parentCollectionName"]
                parent_collection_relative_url_to_root_with_spa = notification["parentCollectionRelativeUrlToRootWithSpa"]
                # message = f'<a href="/dataset.xhtml?persistentId=doi:10.5072/FK2/Y733KJ&amp;version=DRAFT&amp;faces-redirect=true" title="Darwin\'s Finches">{dataset_name}</a> was submitted for review to be published in <a href="/dataverse/dv085f7b38" title="dv085f7b38">dv085f7b38</a>. Don\'t forget to publish it or send it back to the contributor, \
                # message = f'<a href="{dataset_relative_url_to_root_with_spa}" title="{dataset_name}">{dataset_name}</a> was submitted for review to be published in <a href="{parent_collection_relative_url_to_root_with_spa}" title="{parent_collection_name}">{parent_collection_name}</a>. Don\'t forget to publish it or send it back to the contributor, {requestor_first_name} {requestor_last_name} ({requestor_email})!'
                # message = f'foo!'
                message = f'<a href="{dataset_relative_url_to_root_with_spa}" title="{dataset_title}">{dataset_title}</a> was returned by the curator of \
<a href="{parent_collection_relative_url_to_root_with_spa}" title="{parent_collection_name}">{parent_collection_name}</a>.'
                print(f"{message} {notification['sentTimestamp']}")
                print()
            message = re.sub('<[^<]+?>', '', message)
            print(f"{message} {notification['sentTimestamp']}")
            print()
            print()
"""
<ui:fragment rendered="#{item.type == 'SUBMITTEDDS'}">
    <span class="icon-dataset text-icon-inline text-muted"></span>
    <h:outputFormat value="#{bundle['notification.wasSubmittedForReview']}" escape="false">
        <o:param>
            <a href="/dataset.xhtml?persistentId=#{item.theObject.getDataset().getGlobalId()}&amp;version=DRAFT&amp;faces-redirect=true" title="#{item.theObject.getDataset().getDisplayName()}">#{item.theObject.getDataset().getDisplayName()}</a>
        </o:param>
        <o:param>
            <a href="/dataverse/#{item.theObject.getDataset().getOwner().getAlias()}" title="#{item.theObject.getDataset().getOwner().getDisplayName()}">#{item.theObject.getDataset().getOwner().getDisplayName()}</a>
        </o:param>
        <o:param>
            #{DataverseUserPage.getRequestorName(item)}
        </o:param>
        <o:param>
            #{DataverseUserPage.getRequestorEmail(item)}
        </o:param>
    </h:outputFormat>
</ui:fragment>
"""


def construct_url(base_url):
    return f"{base_url}/api/notifications/all"


def fetch_notifications(url, api_token):
    # print(f"Fetching notifications from {url} with API token: {api_token}")
    try:
        request = urlrequest.Request(url)
        request.add_header("X-Dataverse-key", api_token)
        try:
            response = urlrequest.urlopen(request)
        except urlrequest.URLError as e:
            print(
                f"Error: Unable to fetch URL {url}. Reason: {e.reason}. Message: {e.readlines()}"
            )
            sys.exit(1)
        return json.loads(
            response.read().decode(response.info().get_param("charset") or "utf-8")
        )
    except Exception as e:
        print(f"Error fetching notifications from {url}: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
