"""
Library Management System - menu-driven console app.

Uses only the Python standard library (sqlite3). Run:
    python library.py            # interactive menu
    python library.py --reset    # rebuild the database from the SQL files
    python library.py --report   # run every query in sql/03_queries.sql
"""
import sqlite3
import sys
from datetime import date, timedelta
from pathlib import Path

BASE = Path(__file__).resolve().parent
DB_FILE = BASE / "library.db"
SQL_DIR = BASE / "sql"
LOAN_DAYS = 14


# ---------------------------------------------------------------- helpers
def connect():
    conn = sqlite3.connect(DB_FILE)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def reset_database():
    if DB_FILE.exists():
        DB_FILE.unlink()
    with connect() as conn:
        for name in ("01_schema.sql", "02_seed.sql"):
            conn.executescript((SQL_DIR / name).read_text(encoding="utf-8"))
    print(f"Database rebuilt: {DB_FILE.name}")


def print_table(rows, title=None):
    if title:
        print(f"\n== {title} ==")
    rows = list(rows)
    if not rows:
        print("(no rows)")
        return
    headers = rows[0].keys()
    data = [[("" if v is None else str(v)) for v in r] for r in rows]
    widths = [max(len(h), *(len(row[i]) for row in data)) for i, h in enumerate(headers)]
    line = "+".join("-" * (w + 2) for w in widths)
    print(line)
    print(" | ".join(h.ljust(w) for h, w in zip(headers, widths)))
    print(line)
    for row in data:
        print(" | ".join(v.ljust(w) for v, w in zip(row, widths)))
    print(line)


def ask(prompt, cast=str):
    while True:
        raw = input(f"{prompt}: ").strip()
        try:
            return cast(raw)
        except ValueError:
            print("  Invalid value, try again.")


# ---------------------------------------------------------------- features
def search_books(conn):
    term = ask("Title / author keyword")
    rows = conn.execute(
        """
        SELECT b.isbn, b.title,
               COALESCE(GROUP_CONCAT(DISTINCT a.last_name), '-') AS authors,
               v.available || '/' || v.total_copies AS available
        FROM book b
        JOIN v_book_availability v ON v.isbn = b.isbn
        LEFT JOIN book_author ba ON ba.isbn = b.isbn
        LEFT JOIN author a ON a.author_id = ba.author_id
        WHERE b.title LIKE ? OR a.first_name LIKE ? OR a.last_name LIKE ?
        GROUP BY b.isbn
        """,
        (f"%{term}%",) * 3,
    )
    print_table(rows, "Search results")


def add_member(conn):
    name = ask("Full name")
    email = ask("Email")
    phone = ask("Phone")
    mtype = ask("Type (STUDENT/FACULTY/PUBLIC)").upper()
    limit = {"STUDENT": 3, "FACULTY": 8, "PUBLIC": 2}.get(mtype, 3)
    try:
        with conn:
            cur = conn.execute(
                "INSERT INTO member (full_name, email, phone, member_type, max_books) "
                "VALUES (?, ?, ?, ?, ?)",
                (name, email, phone, mtype, limit),
            )
        print(f"Member added with id {cur.lastrowid}")
    except sqlite3.IntegrityError as e:
        print(f"Could not add member: {e}")


def issue_book(conn):
    member_id = ask("Member id", int)
    isbn = ask("ISBN")
    staff_id = ask("Staff id issuing", int)
    copy = conn.execute(
        "SELECT copy_id FROM book_copy WHERE isbn = ? AND status = 'AVAILABLE' LIMIT 1", (isbn,)
    ).fetchone()
    if not copy:
        print("No available copy of that book.")
        return
    today = date.today()
    try:
        with conn:  # transaction: commits on success, rolls back on error
            conn.execute(
                "INSERT INTO loan (copy_id, member_id, staff_id, issue_date, due_date) "
                "VALUES (?, ?, ?, ?, ?)",
                (copy["copy_id"], member_id, staff_id, today.isoformat(),
                 (today + timedelta(days=LOAN_DAYS)).isoformat()),
            )
        print(f"Issued copy #{copy['copy_id']}. Due on {today + timedelta(days=LOAN_DAYS)}.")
    except sqlite3.DatabaseError as e:  # raised by the triggers
        print(f"Refused by database: {e}")


def return_book(conn):
    loan_id = ask("Loan id", int)
    loan = conn.execute(
        "SELECT * FROM loan WHERE loan_id = ? AND return_date IS NULL", (loan_id,)
    ).fetchone()
    if not loan:
        print("No open loan with that id.")
        return
    with conn:
        conn.execute("UPDATE loan SET return_date = ? WHERE loan_id = ?",
                     (date.today().isoformat(), loan_id))
    fine = conn.execute("SELECT amount FROM fine WHERE loan_id = ?", (loan_id,)).fetchone()
    print("Book returned." + (f" Late fine created: Rs {fine['amount']:.2f}" if fine else ""))


def pay_fine(conn):
    member_id = ask("Member id", int)
    rows = conn.execute(
        "SELECT f.fine_id, f.loan_id, f.amount FROM fine f JOIN loan l ON l.loan_id = f.loan_id "
        "WHERE l.member_id = ? AND f.paid = 0", (member_id,)
    ).fetchall()
    if not rows:
        print("No unpaid fines.")
        return
    print_table(rows, "Unpaid fines")
    if ask("Pay all? (y/n)").lower() == "y":
        with conn:
            conn.executemany("UPDATE fine SET paid = 1 WHERE fine_id = ?",
                             [(r["fine_id"],) for r in rows])
        print(f"Paid Rs {sum(r['amount'] for r in rows):.2f}")


def open_loans(conn):
    rows = conn.execute(
        """SELECT l.loan_id, m.full_name AS member, b.title, l.issue_date, l.due_date,
                  CASE WHEN DATE('now') > l.due_date THEN 'OVERDUE' ELSE 'OK' END AS status
           FROM loan l JOIN member m ON m.member_id = l.member_id
           JOIN book_copy bc ON bc.copy_id = l.copy_id JOIN book b ON b.isbn = bc.isbn
           WHERE l.return_date IS NULL ORDER BY l.due_date"""
    )
    print_table(rows, "Open loans")


def run_report_queries(conn):
    text = (SQL_DIR / "03_queries.sql").read_text(encoding="utf-8")
    title, buffer = None, ""
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("--"):          # comment line: maybe a query title
            if stripped.startswith("-- Q"):
                title = stripped.lstrip("- ").strip()
            continue
        buffer += line + "\n"
        if sqlite3.complete_statement(buffer):  # a full statement ending in ';'
            print_table(conn.execute(buffer), title)
            buffer = ""


MENU = [
    ("Search books", search_books),
    ("Book availability", lambda c: print_table(c.execute("SELECT * FROM v_book_availability"), "Availability")),
    ("Add member", add_member),
    ("Issue a book", issue_book),
    ("Return a book", return_book),
    ("Show open loans", open_loans),
    ("Pay fines", pay_fine),
    ("Member summary", lambda c: print_table(c.execute("SELECT * FROM v_member_summary"), "Members")),
    ("Run all report queries", run_report_queries),
]


def main():
    if "--reset" in sys.argv or not DB_FILE.exists():
        reset_database()
    conn = connect()
    if "--report" in sys.argv:
        run_report_queries(conn)
        return
    while True:
        print("\n===== LIBRARY MANAGEMENT SYSTEM =====")
        for i, (label, _) in enumerate(MENU, 1):
            print(f" {i}. {label}")
        print(" 0. Exit")
        try:
            choice = input("Choose: ").strip()
        except (EOFError, KeyboardInterrupt):
            break
        if choice == "0":
            break
        if choice.isdigit() and 1 <= int(choice) <= len(MENU):
            MENU[int(choice) - 1][1](conn)
        else:
            print("Invalid choice.")
    conn.close()


if __name__ == "__main__":
    main()
