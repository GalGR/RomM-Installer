"""Show which MariaDB instance each host:port reaches, and how it sees you.

Run with RomM's venv Python (it has the MariaDB driver):
  ~/opt/romm/app/.venv/bin/python dbcheck.py 127.0.0.1:12715 HOSTNAME-direct.TLD:12715
Same server_id + hostname + uptime on two lines = the same database instance.
"""
import getpass, os, sys
import mariadb

user = os.environ.get("DB_ADMIN_USER") or input("MariaDB admin user: ")
pw = os.environ.get("DB_ADMIN_PASSWD") or getpass.getpass("password: ")
for target in sys.argv[1:]:
    host, _, port = target.rpartition(":")
    try:
        c = mariadb.connect(host=host, port=int(port), user=user, password=pw, connect_timeout=5)
        cur = c.cursor()
        cur.execute("SELECT @@server_id, @@hostname, @@version, USER(), "
                    "(SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='UPTIME')")
        sid, hostname, version, me, uptime = cur.fetchone()
        print(f"{target:40} server_id={sid} hostname={hostname} version={version} uptime={uptime}s you-are={me}")
        c.close()
    except mariadb.Error as ex:
        print(f"{target:40} FAILED: {ex}")
