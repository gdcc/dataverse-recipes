- Write version_of_dataverse.py in pure Python with no dependencies.
- Pull data from https://hub.dataverse.org/api/installations/status
- Show a count of installations with that version.
- With a -i or --installations flag

Here's some example output with no arguments:

6.10.1	3
6.10	5
6.9	4
6.2	8
6.2-IRD1	1
6.1	5
null	9

Here's some example output with -i:
6.10.1	3	host1.example.org,host2.example.org,host3.example.org
