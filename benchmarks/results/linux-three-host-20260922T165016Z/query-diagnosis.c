#include <stdio.h>
#include <string.h>
#include <sqlite3.h>
static int ticks;
static int progress(void *unused) { (void)unused; ticks++; return 0; }
int main(int argc,char **argv) {
 sqlite3 *db=0; sqlite3_stmt *s=0; char sql[2048],explain[2100],payload[257];
 if(argc!=2 || sqlite3_open_v2(argv[1],&db,SQLITE_OPEN_READONLY,0)!=SQLITE_OK) return 1;
 memset(payload,'x',256);payload[256]=0;
 printf("{\"sqlite\":\"%s\",\"queries\":[",sqlite3_libversion());
 for(int variant=0;variant<2;variant++) {
  snprintf(sql,sizeof(sql),"SELECT t.id FROM transfers t JOIN ledger l ON l.tx=t.id WHERE t.id BETWEEN 99011 AND 99042 %s AND t.src=t.id%%3+1 AND t.dst=t.src%%3+1 AND t.amount=t.id%%17+1 AND t.payload='%s' AND ((l.account=t.src AND l.delta=-t.amount) OR (l.account=t.dst AND l.delta=t.amount)) GROUP BY t.id HAVING count(*)=2 AND count(DISTINCT l.account)=2",variant?"AND l.tx BETWEEN 99011 AND 99042":"",payload);
  snprintf(explain,sizeof(explain),"EXPLAIN QUERY PLAN %s",sql);
  if(sqlite3_prepare_v2(db,explain,-1,&s,0)!=SQLITE_OK)return 2;
  printf("%s{\"bounded_ledger_range\":%s,\"plan\":[",variant?",":"",variant?"true":"false");
  int n=0,rc;
  while((rc=sqlite3_step(s))==SQLITE_ROW) printf("%s\"%s\"",n++?",":"",sqlite3_column_text(s,3));
  if(rc!=SQLITE_DONE)return 3;
  sqlite3_finalize(s);
  ticks=0;sqlite3_progress_handler(db,1000,progress,0);
  if(sqlite3_prepare_v2(db,sql,-1,&s,0)!=SQLITE_OK)return 4;
  n=0;while((rc=sqlite3_step(s))==SQLITE_ROW)n++;
  if(rc!=SQLITE_DONE)return 5;
  printf("],\"rows\":%d,\"instructions_lower_bound\":%d}",n,ticks*1000);
  sqlite3_finalize(s);
 }
 printf("]}\n");sqlite3_close(db);return 0;
}
