from pyDataverse import Dataverse

# First, connect to your Dataverse installation
dv = Dataverse(base_url="http://localhost:8080")

# Create a new dataset with basic information
dataset = dv.create_dataset(
    title="My Research Dataset",
    description="A comprehensive dataset containing experimental results from our study on machine learning algorithms",
    authors=[
        {
            "name": "Jane Smith",
            "affiliation": "University of Science",
            "identifier_scheme": "ORCID",  # Optional: identifies the author using ORCID
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
    subjects=["Computer and Information Science", "Engineering"]  # Categories for the dataset
)

# The dataset is now ready to use with all metadata blocks configured
# You can access the citation metadata block like this:
print(dataset.metadata_blocks["citation"].title)
# Output: 'My Research Dataset'
