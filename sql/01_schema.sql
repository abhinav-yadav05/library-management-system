-- =====================================================================
--  Library Management System - Schema (DDL)
--  Target: SQLite 3 (standard SQL; notes show MySQL/Oracle equivalents)
--  All tables are in 3NF / BCNF (see README.md -> Normalization)
-- =====================================================================

PRAGMA foreign_keys = ON;

DROP VIEW    IF EXISTS v_overdue_loans;
DROP VIEW    IF EXISTS v_book_availability;
DROP VIEW    IF EXISTS v_member_summary;
DROP TABLE   IF EXISTS book_stats;
DROP TABLE   IF EXISTS fine;
DROP TABLE   IF EXISTS loan;
DROP TABLE   IF EXISTS book_copy;
DROP TABLE   IF EXISTS book_author;
DROP TABLE   IF EXISTS book;
DROP TABLE   IF EXISTS author;
DROP TABLE   IF EXISTS publisher;
DROP TABLE   IF EXISTS category;
DROP TABLE   IF EXISTS member;
DROP TABLE   IF EXISTS staff;

-- ---------------------------------------------------------------------
-- Strong entities
-- ---------------------------------------------------------------------
CREATE TABLE publisher (
    publisher_id   INTEGER PRIMARY KEY AUTOINCREMENT,
    name           VARCHAR(100) NOT NULL UNIQUE,
    city           VARCHAR(60),
    phone          VARCHAR(20)
);

CREATE TABLE category (
    category_id    INTEGER PRIMARY KEY AUTOINCREMENT,
    name           VARCHAR(60) NOT NULL UNIQUE
);

CREATE TABLE author (
    author_id      INTEGER PRIMARY KEY AUTOINCREMENT,
    first_name     VARCHAR(50) NOT NULL,
    last_name      VARCHAR(50) NOT NULL,
    nationality    VARCHAR(50)
);

CREATE TABLE book (
    isbn           CHAR(13)     PRIMARY KEY,
    title          VARCHAR(200) NOT NULL,
    publisher_id   INTEGER      NOT NULL,
    category_id    INTEGER      NOT NULL,
    pub_year       INTEGER      CHECK (pub_year BETWEEN 1450 AND 2100),
    price          DECIMAL(8,2) NOT NULL CHECK (price >= 0),
    FOREIGN KEY (publisher_id) REFERENCES publisher(publisher_id) ON DELETE RESTRICT,
    FOREIGN KEY (category_id)  REFERENCES category(category_id)   ON DELETE RESTRICT
);

-- M:N relationship BOOK <-> AUTHOR
CREATE TABLE book_author (
    isbn           CHAR(13) NOT NULL,
    author_id      INTEGER  NOT NULL,
    author_order   INTEGER  NOT NULL DEFAULT 1,
    PRIMARY KEY (isbn, author_id),
    FOREIGN KEY (isbn)      REFERENCES book(isbn)          ON DELETE CASCADE,
    FOREIGN KEY (author_id) REFERENCES author(author_id)   ON DELETE CASCADE
);

-- Weak-ish entity: each physical copy of a book
CREATE TABLE book_copy (
    copy_id        INTEGER PRIMARY KEY AUTOINCREMENT,
    isbn           CHAR(13)    NOT NULL,
    shelf          VARCHAR(10) NOT NULL,
    status         VARCHAR(12) NOT NULL DEFAULT 'AVAILABLE'
                   CHECK (status IN ('AVAILABLE','ON_LOAN','LOST','DAMAGED')),
    FOREIGN KEY (isbn) REFERENCES book(isbn) ON DELETE CASCADE
);

CREATE TABLE member (
    member_id      INTEGER PRIMARY KEY AUTOINCREMENT,
    full_name      VARCHAR(100) NOT NULL,
    email          VARCHAR(100) NOT NULL UNIQUE,
    phone          VARCHAR(20),
    member_type    VARCHAR(10)  NOT NULL CHECK (member_type IN ('STUDENT','FACULTY','PUBLIC')),
    join_date      DATE         NOT NULL DEFAULT (DATE('now')),
    max_books      INTEGER      NOT NULL DEFAULT 3 CHECK (max_books BETWEEN 1 AND 10)
);

CREATE TABLE staff (
    staff_id       INTEGER PRIMARY KEY AUTOINCREMENT,
    full_name      VARCHAR(100) NOT NULL,
    role           VARCHAR(30)  NOT NULL CHECK (role IN ('LIBRARIAN','ASSISTANT','ADMIN'))
);

-- Relationship MEMBER borrows BOOK_COPY (issued by STAFF)
CREATE TABLE loan (
    loan_id        INTEGER PRIMARY KEY AUTOINCREMENT,
    copy_id        INTEGER NOT NULL,
    member_id      INTEGER NOT NULL,
    staff_id       INTEGER NOT NULL,
    issue_date     DATE    NOT NULL DEFAULT (DATE('now')),
    due_date       DATE    NOT NULL,
    return_date    DATE,
    CHECK (due_date > issue_date),
    CHECK (return_date IS NULL OR return_date >= issue_date),
    FOREIGN KEY (copy_id)   REFERENCES book_copy(copy_id),
    FOREIGN KEY (member_id) REFERENCES member(member_id),
    FOREIGN KEY (staff_id)  REFERENCES staff(staff_id)
);

-- One fine per late loan (1:1 with loan)
CREATE TABLE fine (
    fine_id        INTEGER PRIMARY KEY AUTOINCREMENT,
    loan_id        INTEGER      NOT NULL UNIQUE,
    amount         DECIMAL(8,2) NOT NULL CHECK (amount > 0),
    paid           INTEGER      NOT NULL DEFAULT 0 CHECK (paid IN (0,1)),
    FOREIGN KEY (loan_id) REFERENCES loan(loan_id) ON DELETE CASCADE
);

-- ---------------------------------------------------------------------
-- Indexes (speed up the most common lookups)
-- ---------------------------------------------------------------------
CREATE INDEX idx_book_title       ON book(title);
CREATE INDEX idx_copy_isbn        ON book_copy(isbn);
CREATE INDEX idx_loan_member      ON loan(member_id);
CREATE INDEX idx_loan_open        ON loan(return_date);

-- ---------------------------------------------------------------------
-- Triggers (business rules enforced inside the database)
-- ---------------------------------------------------------------------

-- R1: A copy can only be issued if it is AVAILABLE
CREATE TRIGGER trg_loan_check_copy
BEFORE INSERT ON loan
WHEN (SELECT status FROM book_copy WHERE copy_id = NEW.copy_id) <> 'AVAILABLE'
BEGIN
    SELECT RAISE(ABORT, 'Copy is not available for loan');
END;

-- R2: A member cannot exceed their borrowing limit
CREATE TRIGGER trg_loan_check_limit
BEFORE INSERT ON loan
WHEN (SELECT COUNT(*) FROM loan WHERE member_id = NEW.member_id AND return_date IS NULL)
     >= (SELECT max_books FROM member WHERE member_id = NEW.member_id)
BEGIN
    SELECT RAISE(ABORT, 'Member has reached the borrowing limit');
END;

-- R3: A member with unpaid fines cannot borrow
CREATE TRIGGER trg_loan_check_fines
BEFORE INSERT ON loan
WHEN EXISTS (SELECT 1 FROM fine f JOIN loan l ON l.loan_id = f.loan_id
             WHERE l.member_id = NEW.member_id AND f.paid = 0)
BEGIN
    SELECT RAISE(ABORT, 'Member has unpaid fines');
END;

-- R4: Issuing a book marks the copy ON_LOAN
CREATE TRIGGER trg_loan_issue
AFTER INSERT ON loan
BEGIN
    UPDATE book_copy SET status = 'ON_LOAN' WHERE copy_id = NEW.copy_id;
END;

-- R5: Returning a book frees the copy and creates a fine (Rs 10/day late)
CREATE TRIGGER trg_loan_return
AFTER UPDATE OF return_date ON loan
WHEN OLD.return_date IS NULL AND NEW.return_date IS NOT NULL
BEGIN
    UPDATE book_copy SET status = 'AVAILABLE' WHERE copy_id = NEW.copy_id;
    INSERT INTO fine (loan_id, amount)
    SELECT NEW.loan_id, (JULIANDAY(NEW.return_date) - JULIANDAY(NEW.due_date)) * 10
    WHERE JULIANDAY(NEW.return_date) > JULIANDAY(NEW.due_date);
END;

-- ---------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------
CREATE VIEW v_book_availability AS
SELECT b.isbn, b.title, c.name AS category,
       COUNT(bc.copy_id)                                        AS total_copies,
       SUM(CASE WHEN bc.status = 'AVAILABLE' THEN 1 ELSE 0 END) AS available
FROM book b
JOIN category c        ON c.category_id = b.category_id
LEFT JOIN book_copy bc ON bc.isbn = b.isbn
GROUP BY b.isbn, b.title, c.name;

CREATE VIEW v_overdue_loans AS
SELECT l.loan_id, m.full_name AS member, b.title, l.issue_date, l.due_date,
       CAST(JULIANDAY('now') - JULIANDAY(l.due_date) AS INTEGER) AS days_overdue
FROM loan l
JOIN member m     ON m.member_id = l.member_id
JOIN book_copy bc ON bc.copy_id  = l.copy_id
JOIN book b       ON b.isbn      = bc.isbn
WHERE l.return_date IS NULL AND DATE('now') > l.due_date;

CREATE VIEW v_member_summary AS
SELECT m.member_id, m.full_name, m.member_type,
       COUNT(l.loan_id)                                          AS total_loans,
       SUM(CASE WHEN l.return_date IS NULL THEN 1 ELSE 0 END)    AS active_loans,
       COALESCE((SELECT SUM(f.amount) FROM fine f JOIN loan l2 ON l2.loan_id = f.loan_id
                 WHERE l2.member_id = m.member_id AND f.paid = 0), 0) AS unpaid_fines
FROM member m
LEFT JOIN loan l ON l.member_id = m.member_id
GROUP BY m.member_id, m.full_name, m.member_type;

-- =====================================================================
--  ADVANCED FEATURES
-- =====================================================================

-- B1. Materialised view maintained incrementally by triggers.
--     A normal view recomputes COUNT(*) over all loans on every read; book_stats
--     stores the answer and triggers keep it correct on every insert/return.
CREATE TABLE book_stats (
    isbn            CHAR(13) PRIMARY KEY REFERENCES book(isbn) ON DELETE CASCADE,
    times_borrowed  INTEGER NOT NULL DEFAULT 0,
    last_borrowed   DATE,
    total_late_days INTEGER NOT NULL DEFAULT 0
);

CREATE TRIGGER trg_stats_new_book AFTER INSERT ON book
BEGIN
    INSERT INTO book_stats (isbn) VALUES (NEW.isbn);
END;

CREATE TRIGGER trg_stats_loan AFTER INSERT ON loan
BEGIN
    UPDATE book_stats
       SET times_borrowed = times_borrowed + 1,
           last_borrowed  = MAX(COALESCE(last_borrowed, ''), NEW.issue_date)
     WHERE isbn = (SELECT isbn FROM book_copy WHERE copy_id = NEW.copy_id);
END;

CREATE TRIGGER trg_stats_return AFTER UPDATE OF return_date ON loan
WHEN OLD.return_date IS NULL AND NEW.return_date > NEW.due_date
BEGIN
    UPDATE book_stats
       SET total_late_days = total_late_days + CAST(JULIANDAY(NEW.return_date) - JULIANDAY(NEW.due_date) AS INTEGER)
     WHERE isbn = (SELECT isbn FROM book_copy WHERE copy_id = NEW.copy_id);
END;

-- B2. Partial index: only OPEN loans are indexed (most loans are closed, so the index stays tiny).
--     Used by the borrowing-limit trigger and the "books out" screens.
CREATE INDEX idx_loan_open_by_member ON loan(member_id) WHERE return_date IS NULL;

-- B3. Expression index: case-insensitive title search can use an index.
CREATE INDEX idx_book_title_lower ON book(LOWER(title));
