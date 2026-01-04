# Telephone Directory Application

A simple telephone directory application with PostgreSQL database, featuring both CLI and web interfaces.

## Features
- Add, edit, delete contacts
- Search by name, phone, or address
- Export contacts to CSV
- Import contacts from CSV
- Clean web interface
- Simple CLI interface

## Prerequisites
- Python 3.8+
- PostgreSQL 12+
- pip (Python package manager)

## Installation

### 1. Setup PostgreSQL
```bash
# Start PostgreSQL service
sudo service postgresql start  # Linux
# or
brew services start postgresql  # MacOS

# Access PostgreSQL
sudo -u postgres psql

# Run the setup script
\i database/setup.sql



# backend setup
cd cli
pip install -r requirements.txt

# Edit database credentials in phone_directory.py
# Update username/password in connect() method

python phone_directory.py


# web application

cd web
pip install -r requirements.txt

# Edit database credentials in app.py
# Update username/password in get_db_connection() function

python app.py
# Open http://localhost:5000 in your browser


Usage Examples
CLI Application
bash
# Add a contact
Name: John Doe
Phone: 555-0101
Address: 123 Main St

# Search contacts
Search term: John

# Export to CSV
Filename: contacts_export.csv


Web Application
Open http://localhost:5000

Use the search box to find contacts

Click "Add Contact" to create new entries

Use edit/delete buttons to manage contacts

Export all contacts as CSV