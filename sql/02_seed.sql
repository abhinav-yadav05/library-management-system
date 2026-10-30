-- =====================================================================
--  Library Management System - Sample Data (DML)
-- =====================================================================
PRAGMA foreign_keys = ON;

INSERT INTO publisher (name, city, phone) VALUES
 ('Pearson',            'London',    '+44-20-1000'),
 ('McGraw Hill',        'New York',  '+1-212-2000'),
 ('O''Reilly Media',    'Sebastopol','+1-707-3000'),
 ('Penguin Random House','New York', '+1-212-4000'),
 ('Ekta Books',         'Kathmandu', '+977-1-5000');

INSERT INTO category (name) VALUES
 ('Computer Science'), ('Database'), ('Fiction'), ('Mathematics'), ('History');

INSERT INTO author (first_name, last_name, nationality) VALUES
 ('Abraham',  'Silberschatz', 'Israeli'),     -- 1
 ('Henry',    'Korth',        'American'),    -- 2
 ('S.',       'Sudarshan',    'Indian'),      -- 3
 ('Ramez',    'Elmasri',      'American'),    -- 4
 ('Shamkant', 'Navathe',      'Indian'),      -- 5
 ('Thomas',   'Cormen',       'American'),    -- 6
 ('Charles',  'Leiserson',    'American'),    -- 7
 ('George',   'Orwell',       'British'),     -- 8
 ('Yuval',    'Harari',       'Israeli'),     -- 9
 ('Gilbert',  'Strang',       'American');    -- 10

INSERT INTO book (isbn, title, publisher_id, category_id, pub_year, price) VALUES
 ('9780078022159', 'Database System Concepts',          2, 2, 2019, 1450.00),
 ('9780133970777', 'Fundamentals of Database Systems',  1, 2, 2015, 1300.00),
 ('9780262033848', 'Introduction to Algorithms',        2, 1, 2009, 1800.00),
 ('9780451524935', '1984',                              4, 3, 1949,  450.00),
 ('9780062316097', 'Sapiens',                           4, 5, 2015,  650.00),
 ('9780980232776', 'Introduction to Linear Algebra',    5, 4, 2016,  990.00),
 ('9781492040347', 'Designing Data-Intensive Apps',     3, 2, 2017, 1650.00),
 ('9780452284234', 'Animal Farm',                       4, 3, 1945,  300.00);

INSERT INTO book_author (isbn, author_id, author_order) VALUES
 ('9780078022159', 1, 1), ('9780078022159', 2, 2), ('9780078022159', 3, 3),
 ('9780133970777', 4, 1), ('9780133970777', 5, 2),
 ('9780262033848', 6, 1), ('9780262033848', 7, 2),
 ('9780451524935', 8, 1),
 ('9780062316097', 9, 1),
 ('9780980232776', 10, 1),
 ('9780452284234', 8, 1);
-- (Designing Data-Intensive Apps intentionally has no author row -> used in an outer-join query)

INSERT INTO book_copy (isbn, shelf) VALUES
 ('9780078022159','DB-01'), ('9780078022159','DB-01'), ('9780078022159','DB-02'),
 ('9780133970777','DB-03'), ('9780133970777','DB-03'),
 ('9780262033848','CS-01'), ('9780262033848','CS-01'),
 ('9780451524935','FI-01'), ('9780451524935','FI-01'),
 ('9780062316097','HI-01'),
 ('9780980232776','MA-01'),
 ('9781492040347','DB-04'),
 ('9780452284234','FI-02');

INSERT INTO member (full_name, email, phone, member_type, join_date, max_books) VALUES
 ('Aarav Sharma',   'aarav@uni.edu',   '9800000001', 'STUDENT', '2025-01-10', 3),
 ('Sita Thapa',     'sita@uni.edu',    '9800000002', 'STUDENT', '2025-02-15', 3),
 ('Dr. Ram Koirala','ram@uni.edu',     '9800000003', 'FACULTY', '2024-08-01', 8),
 ('Priya Gurung',   'priya@mail.com',  '9800000004', 'PUBLIC',  '2025-05-20', 2),
 ('Bikash Rai',     'bikash@uni.edu',  '9800000005', 'STUDENT', '2025-06-01', 3),
 ('Anita Shrestha', 'anita@uni.edu',   '9800000006', 'FACULTY', '2024-09-12', 8),
 ('Kiran Magar',    'kiran@mail.com',  '9800000007', 'PUBLIC',  '2026-10-01', 2);  -- never borrowed

INSERT INTO staff (full_name, role) VALUES
 ('Hari Bhandari', 'LIBRARIAN'),
 ('Gita Karki',    'ASSISTANT'),
 ('Admin User',    'ADMIN');

-- Historical loans (issued, then returned -> triggers fire and create fines when late)
INSERT INTO loan (copy_id, member_id, staff_id, issue_date, due_date) VALUES
 (1, 1, 1, '2026-08-01', '2026-08-15'),   -- loan 1
 (6, 3, 1, '2026-08-05', '2026-09-05'),   -- loan 2
 (8, 2, 2, '2026-08-10', '2026-08-24'),   -- loan 3
 (4, 5, 2, '2026-09-01', '2026-09-15');   -- loan 4

UPDATE loan SET return_date = '2026-08-14' WHERE loan_id = 1;  -- on time
UPDATE loan SET return_date = '2026-09-01' WHERE loan_id = 2;  -- on time
UPDATE loan SET return_date = '2026-08-30' WHERE loan_id = 3;  -- 6 days late -> Rs 60 fine
UPDATE loan SET return_date = '2026-09-25' WHERE loan_id = 4;  -- 10 days late -> Rs 100 fine
UPDATE fine SET paid = 1 WHERE loan_id = 3;                    -- Sita paid her fine

-- Currently open loans
INSERT INTO loan (copy_id, member_id, staff_id, issue_date, due_date) VALUES
 (2,  3, 1, '2026-10-01', '2026-11-01'),  -- Dr. Ram, not due yet
 (7,  1, 1, '2026-09-20', '2026-10-04'),  -- Aarav, overdue
 (10, 6, 2, '2026-10-10', '2026-11-10'),  -- Anita
 (11, 3, 2, '2026-10-12', '2026-11-12'),  -- Dr. Ram
 (9,  4, 1, '2026-09-25', '2026-10-09');  -- Priya, overdue
