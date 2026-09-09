import os

from pyDataverse import Dataverse

api_token = os.getenv("API_TOKEN")
if not api_token:
    raise SystemExit(
        "Error: API_TOKEN is required.\n"
        "Set it before running the script:\n"
        '  export API_TOKEN="your-dataverse-api-token"'
    )

# First, connect to your Dataverse installation
dv = Dataverse(
    base_url=os.getenv("DATAVERSE_URL", "https://demo.dataverse.org"),
    api_token=api_token,
)

# Create a new dataset with basic information
dataset = dv.create_dataset(
    title="My Research Dataset",
    description="A comprehensive dataset containing experimental results from our study on machine learning algorithms",
    authors=[
        {
            "name": "Jane Smith",
            "affiliation": "University of Science",
            # TODO uncomment when this issue is fixed:
            # https://github.com/gdcc/pyDataverse/issues/241
            # The expected error is this: TypeError: issubclass() arg 1 must be a class
            # "identifier_scheme": "ORCID",  # Optional: identifies the author using ORCID
            "identifier": "0000-0000-0000-0000"  # Optional: the actual ORCID number
        }
    ],
    contacts=[
        {
            "name": "Jane Smith",
            "email": "jane.smith@university.edu",
            "affiliation": "University of Science"  # Optional: where they work
        }
    ],
    subjects=["Computer and Information Science", "Engineering"],  # Categories for the dataset
    collection=os.getenv("COLLECTION", ":root")
)

# The dataset is now ready to use with all metadata blocks configured
# You can access the citation metadata block like this:
print(dataset.metadata_blocks["citation"].title)
# Output: 'My Research Dataset'
