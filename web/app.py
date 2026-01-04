# File: web/app.py
from flask import Flask, render_template, request, jsonify, send_file
import psycopg2
from psycopg2 import Error
import csv
import io
import os

app = Flask(__name__)

def get_db_connection():
    """Get database connection using environment variables"""
    try:
        conn = psycopg2.connect(
            host=os.getenv('DATABASE_HOST', 'localhost'),
            database=os.getenv('DATABASE_NAME', 'phone_directory'),
            user=os.getenv('DATABASE_USER', 'postgres'),
            password=os.getenv('DATABASE_PASSWORD', 'postgres'),
            port=os.getenv('DATABASE_PORT', '5432')
        )
        return conn
    except Error as e:
        app.logger.error(f"Database connection error: {e}")
        raise

@app.route('/')
def index():
    """Home page"""
    return render_template('index.html')

@app.route('/health')
def health():
    """Health check endpoint"""
    try:
        conn = get_db_connection()
        conn.close()
        return jsonify({'status': 'healthy', 'database': 'connected'}), 200
    except Exception as e:
        return jsonify({'status': 'unhealthy', 'error': str(e)}), 500

@app.route('/api/contacts', methods=['GET'])
def get_contacts():
    """Get all contacts or search"""
    search = request.args.get('search', '')
    conn = get_db_connection()
    cursor = conn.cursor()
    
    try:
        if search:
            cursor.execute("""
                SELECT id, name, phone, address 
                FROM contacts 
                WHERE name ILIKE %s OR phone ILIKE %s OR address ILIKE %s
                ORDER BY name
            """, (f'%{search}%', f'%{search}%', f'%{search}%'))
        else:
            cursor.execute("SELECT id, name, phone, address FROM contacts ORDER BY name")
        
        contacts = cursor.fetchall()
        return jsonify([{
            'id': c[0],
            'name': c[1],
            'phone': c[2],
            'address': c[3]
        } for c in contacts])
    except Error as e:
        app.logger.error(f"Error fetching contacts: {e}")
        return jsonify({'error': str(e)}), 500
    finally:
        cursor.close()
        conn.close()

@app.route('/api/contacts', methods=['POST'])
def add_contact():
    """Add new contact"""
    data = request.json
    if not data or 'name' not in data or 'phone' not in data:
        return jsonify({'error': 'Name and phone are required'}), 400
    
    conn = get_db_connection()
    cursor = conn.cursor()
    
    try:
        cursor.execute(
            "INSERT INTO contacts (name, phone, address) VALUES (%s, %s, %s) RETURNING id",
            (data['name'], data['phone'], data.get('address', ''))
        )
        
        contact_id = cursor.fetchone()[0]
        conn.commit()
        return jsonify({
            'id': contact_id, 
            'message': 'Contact added successfully!'
        }), 201
    except psycopg2.IntegrityError:
        return jsonify({'error': 'Phone number already exists'}), 400
    except Error as e:
        return jsonify({'error': str(e)}), 500
    finally:
        cursor.close()
        conn.close()

@app.route('/api/contacts/<int:contact_id>', methods=['PUT'])
def update_contact(contact_id):
    """Update existing contact"""
    data = request.json
    if not data or 'name' not in data or 'phone' not in data:
        return jsonify({'error': 'Name and phone are required'}), 400
    
    conn = get_db_connection()
    cursor = conn.cursor()
    
    try:
        cursor.execute("""
            UPDATE contacts 
            SET name = %s, phone = %s, address = %s 
            WHERE id = %s
        """, (data['name'], data['phone'], data.get('address', ''), contact_id))
        
        conn.commit()
        if cursor.rowcount == 0:
            return jsonify({'error': 'Contact not found'}), 404
        
        return jsonify({'message': 'Contact updated successfully!'})
    except Error as e:
        return jsonify({'error': str(e)}), 500
    finally:
        cursor.close()
        conn.close()

@app.route('/api/contacts/<int:contact_id>', methods=['DELETE'])
def delete_contact(contact_id):
    """Delete contact"""
    conn = get_db_connection()
    cursor = conn.cursor()
    
    try:
        cursor.execute("DELETE FROM contacts WHERE id = %s", (contact_id,))
        conn.commit()
        
        if cursor.rowcount == 0:
            return jsonify({'error': 'Contact not found'}), 404
        
        return jsonify({'message': 'Contact deleted successfully!'})
    except Error as e:
        return jsonify({'error': str(e)}), 500
    finally:
        cursor.close()
        conn.close()

@app.route('/api/contacts/export', methods=['GET'])
def export_contacts():
    """Export contacts as CSV"""
    conn = get_db_connection()
    cursor = conn.cursor()
    
    try:
        cursor.execute("SELECT name, phone, address, created_at FROM contacts ORDER BY name")
        contacts = cursor.fetchall()
        
        # Create CSV in memory
        output = io.StringIO()
        writer = csv.writer(output)
        writer.writerow(['Name', 'Phone', 'Address', 'Created At'])
        writer.writerows(contacts)
        
        output.seek(0)
        return send_file(
            io.BytesIO(output.getvalue().encode('utf-8')),
            mimetype='text/csv',
            as_attachment=True,
            download_name='contacts_export.csv'
        )
    except Error as e:
        return jsonify({'error': str(e)}), 500
    finally:
        cursor.close()
        conn.close()

# Production Gunicorn entry point
if __name__ == '__main__':
    # Check if running in development mode
    debug_mode = os.getenv('FLASK_DEBUG', 'false').lower() == 'true'
    
    if debug_mode:
        app.run(debug=True, host='0.0.0.0', port=5000)
    else:
        # In production, Gunicorn will import this file
        pass