"""
Library web portal: a small JSON API + single-page front end (portal.html).
Shares library.db with the console app. Standard library only.

    python portal.py          ->  http://localhost:8100
"""
import json
import os
import sqlite3
from datetime import date, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import library  # reuse connect() / reset_database()

HERE = Path(__file__).resolve().parent
PORT = int(os.environ.get("PORT", 8100))


def rows(conn, sql, args=()):
    return [dict(r) for r in conn.execute(sql, args).fetchall()]


# ---------------------------------------------------------------- API (GET)
def api_stats(c, q):
    one = lambda s: c.execute(s).fetchone()[0]
    return {"titles": one("SELECT COUNT(*) FROM book"),
            "copies": one("SELECT COUNT(*) FROM book_copy"),
            "on_loan": one("SELECT COUNT(*) FROM loan WHERE return_date IS NULL"),
            "overdue": one("SELECT COUNT(*) FROM v_overdue_loans"),
            "members": one("SELECT COUNT(*) FROM member"),
            "fines_due": one("SELECT COALESCE(SUM(amount),0) FROM fine WHERE paid = 0"),
            "top": rows(c, """SELECT b.title, s.times_borrowed AS n FROM book_stats s JOIN book b ON b.isbn = s.isbn
                              ORDER BY n DESC, b.title LIMIT 5""")}


def api_books(c, q):
    term = f"%{q.get('q', [''])[0]}%"
    return rows(c, """
        SELECT b.isbn, b.title, b.pub_year, b.price, c.name AS category, p.name AS publisher,
               COALESCE(GROUP_CONCAT(a.first_name || ' ' || a.last_name, ', '), 'Unknown') AS authors,
               v.available, v.total_copies
        FROM book b JOIN category c ON c.category_id = b.category_id
        JOIN publisher p ON p.publisher_id = b.publisher_id
        JOIN v_book_availability v ON v.isbn = b.isbn
        LEFT JOIN book_author ba ON ba.isbn = b.isbn LEFT JOIN author a ON a.author_id = ba.author_id
        GROUP BY b.isbn
        HAVING b.title LIKE ? OR authors LIKE ? OR category LIKE ?
        ORDER BY b.title""", (term, term, term))


def api_members(c, q):
    return rows(c, "SELECT * FROM v_member_summary ORDER BY full_name")


def api_member(c, q):
    mid = int(q["id"][0])
    info = rows(c, "SELECT * FROM member WHERE member_id = ?", (mid,))
    loans = rows(c, """SELECT l.loan_id, b.title, l.issue_date, l.due_date, l.return_date, f.amount AS fine, f.paid
                       FROM loan l JOIN book_copy bc ON bc.copy_id=l.copy_id JOIN book b ON b.isbn=bc.isbn
                       LEFT JOIN fine f ON f.loan_id=l.loan_id WHERE l.member_id=? ORDER BY l.issue_date DESC""", (mid,))
    return {"member": info[0] if info else None, "loans": loans}


def api_loans(c, q):
    return rows(c, """SELECT l.loan_id, m.full_name AS member, b.title, l.due_date,
                      CAST(JULIANDAY('now') - JULIANDAY(l.due_date) AS INTEGER) AS days_late
                      FROM loan l JOIN member m ON m.member_id=l.member_id
                      JOIN book_copy bc ON bc.copy_id=l.copy_id JOIN book b ON b.isbn=bc.isbn
                      WHERE l.return_date IS NULL ORDER BY l.due_date""")


def api_staff(c, q):
    return rows(c, "SELECT staff_id, full_name FROM staff")


# ---------------------------------------------------------------- API (POST)
def do_issue(c, b):
    copy = c.execute("SELECT copy_id FROM book_copy WHERE isbn=? AND status='AVAILABLE' LIMIT 1", (b["isbn"],)).fetchone()
    if not copy:
        raise ValueError("No free copy of this title")
    due = date.today() + timedelta(days=library.LOAN_DAYS)
    c.execute("INSERT INTO loan (copy_id, member_id, staff_id, issue_date, due_date) VALUES (?,?,?,?,?)",
              (copy[0], int(b["member_id"]), int(b["staff_id"]), date.today().isoformat(), due.isoformat()))
    return f"Copy #{copy[0]} issued, due {due:%d %b %Y}"


def do_return(c, b):
    cur = c.execute("UPDATE loan SET return_date=? WHERE loan_id=? AND return_date IS NULL",
                    (date.today().isoformat(), int(b["loan_id"])))
    if not cur.rowcount:
        raise ValueError("Loan not found or already returned")
    fine = c.execute("SELECT amount FROM fine WHERE loan_id=?", (int(b["loan_id"]),)).fetchone()
    return "Returned" + (f" - late fine Rs {fine[0]:.0f}" if fine else " on time")


def do_pay(c, b):
    n = c.execute("""UPDATE fine SET paid=1 WHERE paid=0 AND loan_id IN
                     (SELECT loan_id FROM loan WHERE member_id=?)""", (int(b["member_id"]),)).rowcount
    return f"{n} fine(s) cleared"


def do_member(c, b):
    limit = {"STUDENT": 3, "FACULTY": 8, "PUBLIC": 2}[b["member_type"]]
    cur = c.execute("INSERT INTO member (full_name, email, phone, member_type, max_books) VALUES (?,?,?,?,?)",
                    (b["full_name"], b["email"], b.get("phone"), b["member_type"], limit))
    return f"Member #{cur.lastrowid} registered"


def api_insights(c, q):
    isbn = q.get("isbn", ["9780078022159"])[0]
    day = q.get("date", ["2026-08-20"])[0]
    return {
        # materialised view (trigger-maintained), no aggregation at read time
        "popularity": rows(c, """SELECT b.isbn, b.title, s.times_borrowed, s.last_borrowed, s.total_late_days
                                 FROM book_stats s JOIN book b ON b.isbn = s.isbn
                                 ORDER BY s.times_borrowed DESC, b.title"""),
        # recommendation: members who borrowed this ISBN also borrowed ...
        "also": rows(c, """SELECT b2.title, COUNT(DISTINCT l1.member_id) AS shared
                           FROM loan l1 JOIN book_copy c1 ON c1.copy_id = l1.copy_id
                           JOIN loan l2 ON l2.member_id = l1.member_id AND l2.loan_id <> l1.loan_id
                           JOIN book_copy c2 ON c2.copy_id = l2.copy_id JOIN book b2 ON b2.isbn = c2.isbn
                           WHERE c1.isbn = ? AND c2.isbn <> c1.isbn
                           GROUP BY b2.isbn ORDER BY shared DESC, b2.title""", (isbn,)),
        # temporal point-in-time query
        "asof": rows(c, """SELECT b.title, m.full_name AS borrower, l.issue_date, l.due_date
                           FROM loan l JOIN book_copy bc ON bc.copy_id = l.copy_id JOIN book b ON b.isbn = bc.isbn
                           JOIN member m ON m.member_id = l.member_id
                           WHERE l.issue_date <= ? AND (l.return_date IS NULL OR l.return_date > ?)
                           ORDER BY l.issue_date""", (day, day)),
    }


GET = {"/api/insights": api_insights, "/api/stats": api_stats, "/api/books": api_books, "/api/members": api_members,
       "/api/member": api_member, "/api/loans": api_loans, "/api/staff": api_staff}
POST = {"/api/issue": do_issue, "/api/return": do_return, "/api/pay": do_pay, "/api/members": do_member}


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlparse(self.path)
        if url.path in ("/", "/index.html"):
            return self.reply(200, (HERE / "portal.html").read_bytes(), "text/html")
        fn = GET.get(url.path)
        if not fn:
            return self.reply(404, {"error": "not found"})
        conn = library.connect()
        try:
            self.reply(200, fn(conn, parse_qs(url.query)))
        finally:
            conn.close()

    def do_POST(self):
        fn = POST.get(self.path)
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or "{}")
        conn = library.connect()
        try:
            with conn:  # one transaction per request
                msg = fn(conn, body)
            self.reply(200, {"ok": msg})
        except (sqlite3.Error, ValueError, KeyError) as e:
            self.reply(400, {"error": str(e)})
        finally:
            conn.close()

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    import sys
    if "--reset" in sys.argv or not library.DB_FILE.exists():
        library.reset_database()
    print(f"Library portal on http://localhost:{PORT}  (Ctrl+C to stop)")
    try:
        ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
    except KeyboardInterrupt:
        pass
