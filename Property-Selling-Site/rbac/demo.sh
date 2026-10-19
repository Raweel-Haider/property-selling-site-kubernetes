#!/usr/bin/env bash
# Shows that each user can manage ONLY its own component's namespace (run as admin).
ask() {   # ask <user> <verb> <resource> <namespace>
  r=$(kubectl auth can-i "$2" "$3" -n "$4" --as "$1" 2>/dev/null)
  [ "$r" = yes ] && c='\033[32m' || c='\033[31m'
  printf "  %-30s %b%s%b\n" "$2 $3 in ${4#urban-hive-}" "$c" "$r" '\033[0m'
}
demo() {  # demo <user> <own-ns> <other-ns> <other-ns>
  echo; echo "== $1 (owns ${2#urban-hive-}) =="
  ask $1 list pods $2
  ask $1 create pods $2
  ask $1 delete pods $2
  ask $1 list pods $3
  ask $1 create pods $4
}
demo f-user urban-hive-frontend urban-hive-backend  urban-hive-postgres
demo b-user urban-hive-backend  urban-hive-frontend urban-hive-minio
demo p-user urban-hive-postgres urban-hive-backend  urban-hive-minio
demo m-user urban-hive-minio    urban-hive-postgres urban-hive-frontend
