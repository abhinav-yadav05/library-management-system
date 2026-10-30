-- =====================================================================
--  Library Management System - Report Queries
--  Covers: selection, projection, joins (inner/outer/self), aggregation,
--  GROUP BY / HAVING, nested & correlated sub-queries, set operations,
--  EXISTS / NOT EXISTS, views, CASE, and a transaction.
-- =====================================================================

-- Q1. (Selection + projection) Books published after 2010, costliest first
SELECT isbn, title, pub_year, price
FROM book
WHERE pub_year > 2010
ORDER BY price DESC;

-- Q2. (Multi-table INNER JOIN) Each book with its authors, publisher and category
SELECT b.title,
       GROUP_CONCAT(a.first_name || ' ' || a.last_name, ', ') AS authors,
       p.name AS publisher, c.name AS category
FROM book b
JOIN book_author ba ON ba.isbn = b.isbn
JOIN author a       ON a.author_id = ba.author_id
JOIN publisher p    ON p.publisher_id = b.publisher_id
JOIN category c     ON c.category_id = b.category_id
GROUP BY b.isbn
ORDER BY b.title;

-- Q3. (LEFT OUTER JOIN) Books that have no author recorded
SELECT b.isbn, b.title
FROM book b
LEFT JOIN book_author ba ON ba.isbn = b.isbn
WHERE ba.author_id IS NULL;

-- Q4. (GROUP BY + HAVING) Categories that own more than 2 physical copies
SELECT c.name AS category, COUNT(bc.copy_id) AS copies
FROM category c
JOIN book b       ON b.category_id = c.category_id
JOIN book_copy bc ON bc.isbn = b.isbn
GROUP BY c.name
HAVING COUNT(bc.copy_id) > 2
ORDER BY copies DESC;

-- Q5. (Nested sub-query) Books priced above the average price
SELECT title, price
FROM book
WHERE price > (SELECT AVG(price) FROM book);

-- Q6. (Correlated sub-query) The most expensive book in every category
SELECT c.name AS category, b.title, b.price
FROM book b
JOIN category c ON c.category_id = b.category_id
WHERE b.price = (SELECT MAX(b2.price) FROM book b2 WHERE b2.category_id = b.category_id);

-- Q7. (NOT EXISTS) Members who have never borrowed a book
SELECT m.member_id, m.full_name
FROM member m
WHERE NOT EXISTS (SELECT 1 FROM loan l WHERE l.member_id = m.member_id);

-- Q8. (Set operation UNION) Everyone in the system: members and staff
SELECT full_name, 'MEMBER' AS kind FROM member
UNION
SELECT full_name, 'STAFF'  AS kind FROM staff
ORDER BY kind, full_name;

-- Q9. (EXCEPT / set difference) Titles that have never been borrowed
SELECT b.isbn, b.title FROM book b
EXCEPT
SELECT b.isbn, b.title
FROM book b
JOIN book_copy bc ON bc.isbn = b.isbn
JOIN loan l       ON l.copy_id = bc.copy_id;

-- Q9b. (INTERSECT) Members who borrowed BOTH a Database book and a Mathematics book
SELECT l.member_id FROM loan l
JOIN book_copy bc ON bc.copy_id = l.copy_id JOIN book b ON b.isbn = bc.isbn
JOIN category c ON c.category_id = b.category_id WHERE c.name = 'Database'
INTERSECT
SELECT l.member_id FROM loan l
JOIN book_copy bc ON bc.copy_id = l.copy_id JOIN book b ON b.isbn = bc.isbn
JOIN category c ON c.category_id = b.category_id WHERE c.name = 'Mathematics';

-- Q10. (Self join) Pairs of members of the same type
SELECT m1.full_name AS member_1, m2.full_name AS member_2, m1.member_type
FROM member m1
JOIN member m2 ON m1.member_type = m2.member_type AND m1.member_id < m2.member_id;

-- Q11. (View) Current availability of every title
SELECT * FROM v_book_availability ORDER BY available ASC;

-- Q12. (View) Overdue loans right now
SELECT * FROM v_overdue_loans ORDER BY days_overdue DESC;

-- Q13. (View + CASE) Member summary with a status label
SELECT member_id, full_name, total_loans, active_loans, unpaid_fines,
       CASE WHEN unpaid_fines > 0 THEN 'BLOCKED'
            WHEN active_loans = 0 THEN 'IDLE'
            ELSE 'ACTIVE' END AS status
FROM v_member_summary;

-- Q14. (Aggregates) Top 3 most-borrowed titles
SELECT b.title, COUNT(*) AS times_borrowed
FROM loan l
JOIN book_copy bc ON bc.copy_id = l.copy_id
JOIN book b       ON b.isbn = bc.isbn
GROUP BY b.title
ORDER BY times_borrowed DESC, b.title
LIMIT 3;

-- Q15. (Aggregates) Fine collection report
SELECT SUM(CASE WHEN paid = 1 THEN amount ELSE 0 END) AS collected,
       SUM(CASE WHEN paid = 0 THEN amount ELSE 0 END) AS outstanding,
       COUNT(*) AS total_fines
FROM fine;

-- Q16. (Transaction) Return a book and pay its fine atomically
-- BEGIN TRANSACTION;
--   UPDATE loan SET return_date = DATE('now') WHERE loan_id = 6;
--   UPDATE fine SET paid = 1 WHERE loan_id = 6;
-- COMMIT;     -- or ROLLBACK; to undo both

-- Q17. (Materialised view) Popularity table maintained by triggers
SELECT b.title, s.times_borrowed, s.last_borrowed, s.total_late_days
FROM book_stats s JOIN book b ON b.isbn = s.isbn
ORDER BY s.times_borrowed DESC, b.title;

-- Q18. (Consistency check) Materialised view vs live aggregate: EXCEPT returns no rows when they agree
SELECT isbn, times_borrowed FROM book_stats
EXCEPT
SELECT b.isbn, COUNT(l.loan_id) FROM book b
LEFT JOIN book_copy bc ON bc.isbn = b.isbn LEFT JOIN loan l ON l.copy_id = bc.copy_id
GROUP BY b.isbn;

-- Q19. (Recommendation: self-join on loans) Readers of 'Database System Concepts' also borrowed...
SELECT b2.title AS also_borrowed, COUNT(DISTINCT l1.member_id) AS shared_readers
FROM loan l1
JOIN book_copy c1 ON c1.copy_id = l1.copy_id
JOIN loan l2      ON l2.member_id = l1.member_id AND l2.loan_id <> l1.loan_id
JOIN book_copy c2 ON c2.copy_id = l2.copy_id
JOIN book b2      ON b2.isbn = c2.isbn
WHERE c1.isbn = '9780078022159' AND c2.isbn <> c1.isbn
GROUP BY b2.isbn ORDER BY shared_readers DESC, also_borrowed;

-- Q20. (Temporal / point-in-time query) Which books were out on 20 Aug 2026?
SELECT b.title, m.full_name AS borrower, l.issue_date, COALESCE(l.return_date, 'not yet') AS returned
FROM loan l
JOIN book_copy bc ON bc.copy_id = l.copy_id JOIN book b ON b.isbn = bc.isbn
JOIN member m ON m.member_id = l.member_id
WHERE l.issue_date <= '2026-08-20' AND (l.return_date IS NULL OR l.return_date > '2026-08-20');

-- Q21. (Query optimisation) Plan for the borrowing-limit check: uses the PARTIAL index
EXPLAIN QUERY PLAN
SELECT COUNT(*) FROM loan WHERE member_id = 3 AND return_date IS NULL;

-- Q22. (Query optimisation) Plan for case-insensitive title lookup: uses the EXPRESSION index
EXPLAIN QUERY PLAN
SELECT isbn FROM book WHERE LOWER(title) = 'sapiens';
