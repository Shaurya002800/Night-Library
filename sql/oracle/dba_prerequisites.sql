-- DBA review/action required. Change this owner name to the institution-approved schema owner.
-- Do not grant this package to the runtime application account.
DEFINE OWNER_USER = NIGHT_OWNER
GRANT EXECUTE ON SYS.DBMS_CRYPTO TO &OWNER_USER;
