# File: cli/phone_directory.py
# Main CLI application
import psycopg2
from psycopg2 import Error
import sys
import csv
import os
import time

class PhoneDirectory:
    def __init__(self):
        self.connection = None
        self.connect()
    
    def connect(self):
        """Establish database connection"""
        max_retries = 5
        retry_delay = 5
        
        for attempt in range(max_retries):
            try:
                # Get database connection details from environment variables
                db_host = os.environ.get('DATABASE_HOST', 'localhost')
                db_port = os.environ.get('DATABASE_PORT', '5432')
                db_name = os.environ.get('DATABASE_NAME', 'phone_directory')
                db_user = os.environ.get('DATABASE_USER', 'postgres')
                db_password = os.environ.get('DATABASE_PASSWORD', 'postgres')
                
                print(f"Attempting to connect to PostgreSQL at {db_host}:{db_port}...")
                
                self.connection = psycopg2.connect(
                    host=db_host,
                    port=db_port,
                    database=db_name,
                    user=db_user,
                    password=db_password,
                    connect_timeout=10
                )
                print("✓ Connected to PostgreSQL database successfully!")
                return True
            except Error as e:
                print(f"✗ Attempt {attempt + 1}/{max_retries} failed: {e}")
                if attempt < max_retries - 1:
                    print(f"Retrying in {retry_delay} seconds...")
                    time.sleep(retry_delay)
                else:
                    print("\nPlease ensure:")
                    print("1. PostgreSQL is running")
                    print("2. Database exists and is accessible")
                    print("3. Check connection details in environment variables")
                    print(f"   Host: {db_host}")
                    print(f"   Port: {db_port}")
                    print(f"   Database: {db_name}")
                    print(f"   User: {db_user}")
                    return False
    
    def add_contact(self, name, phone, address=""):
        """Add a new contact to the directory"""
        try:
            cursor = self.connection.cursor()
            cursor.execute(
                "INSERT INTO contacts (name, phone, address) VALUES (%s, %s, %s)",
                (name, phone, address)
            )
            self.connection.commit()
            print(f"✓ Contact '{name}' added successfully!")
            return True
        except psycopg2.IntegrityError:
            print(f"✗ Phone number '{phone}' already exists!")
            return False
        except Error as e:
            print(f"✗ Error adding contact: {e}")
            return False
    
    def search_contacts(self, search_term):
        """Search contacts by name, phone, or address"""
        try:
            cursor = self.connection.cursor()
            cursor.execute("""
                SELECT id, name, phone, address 
                FROM contacts 
                WHERE name ILIKE %s OR phone ILIKE %s OR address ILIKE %s
                ORDER BY name
            """, (f'%{search_term}%', f'%{search_term}%', f'%{search_term}%'))
            
            results = cursor.fetchall()
            return results
        except Error as e:
            print(f"✗ Error searching contacts: {e}")
            return []
    
    def view_all_contacts(self):
        """View all contacts in the directory"""
        try:
            cursor = self.connection.cursor()
            cursor.execute("SELECT id, name, phone, address FROM contacts ORDER BY name")
            return cursor.fetchall()
        except Error as e:
            print(f"✗ Error fetching contacts: {e}")
            return []
    
    def update_contact(self, contact_id, name, phone, address=""):
        """Update an existing contact"""
        try:
            cursor = self.connection.cursor()
            cursor.execute("""
                UPDATE contacts 
                SET name = %s, phone = %s, address = %s 
                WHERE id = %s
            """, (name, phone, address, contact_id))
            self.connection.commit()
            if cursor.rowcount > 0:
                print(f"✓ Contact ID {contact_id} updated successfully!")
                return True
            else:
                print(f"✗ Contact ID {contact_id} not found!")
                return False
        except Error as e:
            print(f"✗ Error updating contact: {e}")
            return False
    
    def delete_contact(self, contact_id):
        """Delete a contact"""
        try:
            cursor = self.connection.cursor()
            cursor.execute("DELETE FROM contacts WHERE id = %s", (contact_id,))
            self.connection.commit()
            if cursor.rowcount > 0:
                print(f"✓ Contact ID {contact_id} deleted successfully!")
                return True
            else:
                print(f"✗ Contact ID {contact_id} not found!")
                return False
        except Error as e:
            print(f"✗ Error deleting contact: {e}")
            return False
    
    def export_to_csv(self, filename="contacts_export.csv"):
        """Export all contacts to CSV file"""
        try:
            contacts = self.view_all_contacts()
            if not contacts:
                print("✗ No contacts to export!")
                return False
            
            with open(filename, 'w', newline='', encoding='utf-8') as file:
                writer = csv.writer(file)
                writer.writerow(['ID', 'Name', 'Phone', 'Address', 'Created At'])
                
                cursor = self.connection.cursor()
                cursor.execute("SELECT id, name, phone, address, created_at FROM contacts ORDER BY name")
                
                for row in cursor.fetchall():
                    writer.writerow(row)
            
            print(f"✓ Exported {len(contacts)} contacts to '{filename}'")
            return True
        except Error as e:
            print(f"✗ Error exporting contacts: {e}")
            return False
    
    def import_from_csv(self, filename):
        """Import contacts from CSV file"""
        try:
            if not os.path.exists(filename):
                print(f"✗ File '{filename}' not found!")
                return False
            
            imported_count = 0
            skipped_count = 0
            
            with open(filename, 'r', encoding='utf-8') as file:
                reader = csv.DictReader(file)
                for row in reader:
                    # Skip header row if already read
                    if 'Name' in row:
                        name = row['Name']
                        phone = row.get('Phone', row.get('phone', ''))
                        address = row.get('Address', row.get('address', ''))
                        
                        if name and phone:
                            if self.add_contact(name, phone, address):
                                imported_count += 1
                            else:
                                skipped_count += 1
            
            print(f"✓ Imported {imported_count} contacts")
            if skipped_count > 0:
                print(f"✗ Skipped {skipped_count} contacts (duplicates or errors)")
            return True
        except Exception as e:
            print(f"✗ Error importing contacts: {e}")
            return False
    
    def close(self):
        """Close database connection"""
        if self.connection:
            self.connection.close()
            print("✓ Database connection closed.")

def display_contacts(contacts):
    """Display contacts in a formatted table"""
    if not contacts:
        print("No contacts found.")
        return
    
    print("\n" + "="*80)
    print(f"{'ID':<4} {'Name':<25} {'Phone':<15} {'Address':<35}")
    print("="*80)
    
    for contact in contacts:
        contact_id, name, phone, address = contact
        # Truncate long addresses for display
        if address and len(address) > 32:
            display_address = address[:29] + '...'
        else:
            display_address = address or "(No address)"
        print(f"{contact_id:<4} {name:<25} {phone:<15} {display_address:<35}")
    print("="*80)

def main():
    """Main CLI interface"""
    directory = PhoneDirectory()
    
    # Check if connection was successful
    if not directory.connection:
        print("\nPlease fix database connection and try again.")
        return
    
    print("\n" + "📞" + "="*38 + "📞")
    print("      TELEPHONE DIRECTORY APPLICATION")
    print("📞" + "="*38 + "📞")
    
    while True:
        print("\n📋 MAIN MENU:")
        print(" 1. Add New Contact")
        print(" 2. Search Contacts")
        print(" 3. View All Contacts")
        print(" 4. Update Contact")
        print(" 5. Delete Contact")
        print(" 6. Export to CSV")
        print(" 7. Import from CSV")
        print(" 8. Exit")
        
        choice = input("\nEnter your choice (1-8): ").strip()
        
        if choice == '1':
            print("\n" + "-"*40)
            print("ADD NEW CONTACT")
            print("-"*40)
            name = input("Name: ").strip()
            phone = input("Phone: ").strip()
            address = input("Address (optional): ").strip()
            
            if name and phone:
                directory.add_contact(name, phone, address)
            else:
                print("✗ Name and phone are required!")
        
        elif choice == '2':
            print("\n" + "-"*40)
            print("SEARCH CONTACTS")
            print("-"*40)
            search_term = input("Search (name, phone, or address): ").strip()
            if search_term:
                results = directory.search_contacts(search_term)
                display_contacts(results)
                print(f"\nFound {len(results)} contact(s).")
            else:
                print("✗ Please enter a search term.")
        
        elif choice == '3':
            print("\n" + "-"*40)
            print("ALL CONTACTS")
            print("-"*40)
            contacts = directory.view_all_contacts()
            display_contacts(contacts)
            print(f"\nTotal: {len(contacts)} contact(s)")
        
        elif choice == '4':
            print("\n" + "-"*40)
            print("UPDATE CONTACT")
            print("-"*40)
            try:
                contact_id = int(input("Contact ID to update: "))
                name = input("New name: ").strip()
                phone = input("New phone: ").strip()
                address = input("New address (optional): ").strip()
                
                if name and phone:
                    directory.update_contact(contact_id, name, phone, address)
                else:
                    print("✗ Name and phone are required!")
            except ValueError:
                print("✗ Please enter a valid ID number.")
        
        elif choice == '5':
            print("\n" + "-"*40)
            print("DELETE CONTACT")
            print("-"*40)
            try:
                contact_id = int(input("Contact ID to delete: "))
                confirm = input(f"Delete contact ID {contact_id}? (y/N): ").strip().lower()
                if confirm == 'y':
                    directory.delete_contact(contact_id)
                else:
                    print("Deletion cancelled.")
            except ValueError:
                print("✗ Please enter a valid ID number.")
        
        elif choice == '6':
            print("\n" + "-"*40)
            print("EXPORT TO CSV")
            print("-"*40)
            filename = input("Filename (default: contacts_export.csv): ").strip()
            if not filename:
                filename = "contacts_export.csv"
            directory.export_to_csv(filename)
        
        elif choice == '7':
            print("\n" + "-"*40)
            print("IMPORT FROM CSV")
            print("-"*40)
            filename = input("CSV file to import: ").strip()
            if filename:
                directory.import_from_csv(filename)
            else:
                print("✗ Please enter a filename.")
        
        elif choice == '8':
            print("\n👋 Goodbye!")
            break
        
        else:
            print("✗ Invalid choice. Please enter a number between 1-8.")
    
    directory.close()

if __name__ == "__main__":
    main()