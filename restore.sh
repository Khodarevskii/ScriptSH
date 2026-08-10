#!/bin/bash -e

# Version 3.16.1
VERSION="3.16.1"
COMMAND_LINE="$0 $*"
error_output=/dev/null

if [[ -v VI_DEBUG ]]; then
  set -x
  error_output=/dev/fd/1
fi

SCRIPT_DIR=$( dirname -- "$( readlink -f -- "$0")")
pushd "${SCRIPT_DIR}"

# Exit codes:
EXIT_OK=0
WRONG_ARGUMENTS_COUNT=15
INVALID_ARGUMENT=20
UNKNOWN_KEY=127

# Defines
TRUE="true"
FALSE="false"
UNDEFINED=255

source config.env
source defaults.env

MAIN_BACKUP_DIR="${BACKUP_DIR%/}/backup"
DV_CUSTOM_SCRIPTS_HOST_PATH="${MAIN_BACKUP_DIR}/dashboard-viewer"
DV_CUSTOM_SCRIPTS_CONTAINER_PATH="${PERSISTENT_STORAGE_FOLDER}/dashboard-viewer/customjs"
MN_FILES_HOST_PATH="${MAIN_BACKUP_DIR}/minio"
MN_FILES_CONTAINER_PATH="/data"
SECRETS_FILES_HOST_PATH="${MAIN_BACKUP_DIR}/secrets"
EXTENDED_SERVICES_PATH="extended-services"
ENV_FILES_PATH="env-files"
CUSTOM_CONFIGS_PATH="custom-configs"
COMMAND_FILE="command.txt"

#PROJECT="visiology3" in config.env
#KEYCLOAK_REALM="Visiology" in defaults.env

# Variables
withPostgresFlag=${UNDEFINED}
withClickhouseFlag=${UNDEFINED}
withSFFlag=${UNDEFINED}
withKeycloakFlag=${UNDEFINED}
withMinioFlag=${UNDEFINED}
withDmSecretKeyFlag=${UNDEFINED}
withAiSecretKeyFlag=${UNDEFINED}
withMailFlag=${UNDEFINED}
withCustomFlag=${UNDEFINED}
withOnecFlag=${UNDEFINED}

WITH_POSTGRES=${TRUE}
WITH_CLICKHOUSE=${TRUE}
WITH_SF=${TRUE}
WITH_KEYCLOAK=${FALSE}
WITH_MINIO=${TRUE}
WITH_DM_SECRET_KEY=${TRUE}
WITH_AI_SECRET_KEY=${FALSE}
WITH_MAIL=${FALSE}
WITH_CUSTOM=${TRUE}
WITH_ONEC=${FALSE}

databases_str=""

### Functions
print_help() {
  echo
  echo "Usage: $0 [OPTIONS]"
  echo "   -? | -h | --help                     Display this help message."
  echo "   -d | --debug                         Optional. Launches in debug mode."
  echo "   --with-postgres <${TRUE}|${FALSE}>         Create backup with Postgres data. Default: ${TRUE}"
  echo "   --with-clickhouse <${TRUE}|${FALSE}>       Create backup with ClickHouse data. Default: ${TRUE}"
  echo "   --with-sf <${TRUE}|${FALSE}>               Create backup with Smart Forms. Default: ${TRUE}"
  echo "   --with-keycloak <${TRUE}|${FALSE}>         Create backup with KeyCloak data. Default: ${FALSE}"
  echo "   --with-minio <${TRUE}|${FALSE}>            Create backup with Minio data (xlsx/csv/images files). Default: ${TRUE}"
  echo "   --with-dm-secret-key <${TRUE}|${FALSE}>    Create backup with DATA_MANAGEMENT_SECRET_KEY. Default: ${TRUE}"
  echo "   --with-ai-secret-key <${TRUE}|${FALSE}>    Create backup with AI_API_KEY. Default: ${FALSE}"
  echo "   --with-mail <${TRUE}|${FALSE}>             Create backup with mail settings. Default: ${FALSE}"
  echo "   --with-custom-settings <${TRUE}|${FALSE}>  Create backup with services custom settings. Default: ${TRUE}"
  echo "   --with-onec <${TRUE}|${FALSE}>             Create backup with onec data. Default: ${FALSE}"
  echo
}

check_input_arguments() {
  # Arguments:
  #  1) variable for checking
  #  2) parameter name
  if [ $# != 2 ]; then
    echo "Function 'check_input_arguments' has wrong arguments count: need 2, has $#. Arguments: $*" >&2
    exit "${WRONG_ARGUMENTS_COUNT}"
  fi

  if [ "$1" != "${TRUE}" ] && [ "$1" != "${FALSE}" ]; then
    echo "Invalid value '$1' of argument '$2'. See help: $0 -h" >&2
    exit "${INVALID_ARGUMENT}"
  fi

  echo "$1"
}
###

# Parse command line arguments
while [ "$1" != "" ]; do
  case "$1" in
    "-?" | "-h" | "--help")
      print_help
      exit ${EXIT_OK}
    ;;
    "-d" | "--debug")
      set -x
    ;;
    "--with-postgres")
     shift
      withPostgresFlag="$1"
      ;;
    "--with-clickhouse")
      shift
      withClickhouseFlag="$1"
      ;;
    "--with-keycloak")
      shift
      withKeycloakFlag="$1"
      ;;
    "--with-minio")
      shift
      withMinioFlag="$1"
      ;;
    "--with-dm-secret-key")
      shift
      withDmSecretKeyFlag="$1"
      ;;
    "--with-ai-secret-key")
      shift
      withAiSecretKeyFlag="$1"
      ;;
    "--with-mail")
      shift
      withMailFlag="$1"
      ;;
    "--with-sf")
      shift
      withSFFlag="$1"
      ;;
    "--with-custom-settings")
      shift
      withCustomFlag="$1"
      ;;
    "--with-onec")
      shift
      withOnecFlag="$1"
      ;;
    *)
      echo "Unknown key: $1"
      print_help
      exit ${UNKNOWN_KEY}
      ;;
  esac
  shift
done
###


### Backup databases checking arguments
if [ "${withPostgresFlag}" != "${UNDEFINED}" ]; then
  WITH_POSTGRES=$(check_input_arguments "${withPostgresFlag}" '--with-postgres')
fi

if [ "${withClickhouseFlag}" != "${UNDEFINED}" ]; then
  WITH_CLICKHOUSE=$(check_input_arguments "${withClickhouseFlag}" '--with-clickhouse')
fi

if [ "${withKeycloakFlag}" != "${UNDEFINED}" ]; then
  WITH_KEYCLOAK=$(check_input_arguments "${withKeycloakFlag}" '--with-keycloak')
fi

if [ "${withMinioFlag}" != "${UNDEFINED}" ]; then
  WITH_MINIO=$(check_input_arguments "${withMinioFlag}" '--with-minio')
fi

if [ "${withDmSecretKeyFlag}" != "${UNDEFINED}" ]; then
  WITH_DM_SECRET_KEY=$(check_input_arguments "${withDmSecretKeyFlag}" '--with-dm-secret-key')
fi

if [ "${withAiSecretKeyFlag}" != "${UNDEFINED}" ]; then
  WITH_AI_SECRET_KEY=$(check_input_arguments "${withAiSecretKeyFlag}" '--with-ai-secret-key')
fi

if [ "${withMailFlag}" != "${UNDEFINED}" ]; then
  WITH_MAIL=$(check_input_arguments "${withMailFlag}" '--with-mail')
fi

if [ "${withSFFlag}" != "${UNDEFINED}" ]; then
  WITH_SF=$(check_input_arguments "${withSFFlag}" '--with-sf')
fi

if [ "${withCustomFlag}" != "${UNDEFINED}" ]; then
  WITH_CUSTOM=$(check_input_arguments "${withCustomFlag}" '--with-custom-settings')
fi

if [ "${withOnecFlag}" != "${UNDEFINED}" ]; then
  WITH_ONEC=$(check_input_arguments "${withOnecFlag}" '--with-onec')
fi
###

### Databases str
if [ "${WITH_POSTGRES}" = ${TRUE} ]; then
  databases_str='"postgres"'
fi

if [ "${WITH_CLICKHOUSE}" = ${TRUE} ]; then
  databases_str=${databases_str}${databases_str:+,}' "clickhouse"'
fi

if [ "${WITH_SF}" = ${TRUE} ]; then
  databases_str=${databases_str}${databases_str:+,}' "smartforms"'
fi

if [ "${WITH_ONEC}" = ${TRUE} ]; then
  databases_str=${databases_str}${databases_str:+,}' "onec"'
fi

databases_str='['${databases_str}']'
###

### Clean up backup dir
rm -rf ${MAIN_BACKUP_DIR}/*

### Store command
echo $COMMAND_LINE > ${MAIN_BACKUP_DIR}/${COMMAND_FILE}

# Backup Databases
container_id=$(docker ps | grep "${PROJECT}_backup-service" |  awk '{ print $1 }')
docker exec "${container_id}" curl -sLv --request POST --url http://127.0.0.1:8000 --header 'Content-Type: application/json' --data '{"command":"backup","databases":'"${databases_str}"',"is_cleanup":true}'

# Backup custom scripts
mkdir -p ${DV_CUSTOM_SCRIPTS_HOST_PATH}
cp -ra "${DV_CUSTOM_SCRIPTS_CONTAINER_PATH}" ${DV_CUSTOM_SCRIPTS_HOST_PATH}

if [ "${WITH_CUSTOM}" = ${TRUE} ]; then
  # Backup extended services
  cp -ra "${EXTENDED_SERVICES_PATH}" ${MAIN_BACKUP_DIR}/${EXTENDED_SERVICES_PATH}

  # Backup env files
  cp -ra "${ENV_FILES_PATH}" ${MAIN_BACKUP_DIR}/${ENV_FILES_PATH}

  # Backup custom configs
  cp -ra "${CUSTOM_CONFIGS_PATH}" ${MAIN_BACKUP_DIR}/${CUSTOM_CONFIGS_PATH}
fi

# Backup KeyCloak
if [ "${WITH_KEYCLOAK}" = ${TRUE} ]; then
  keycloak_container_id=$(docker ps | grep "${PROJECT}_keycloak" |  awk '{ print $1 }')
  docker exec -it "${keycloak_container_id}" /opt/keycloak/bin/kc.sh export --file /opt/keycloak/visiology-realm.json --realm "${KEYCLOAK_REALM}" > ${error_output} || true
  docker cp "${keycloak_container_id}":/opt/keycloak/visiology-realm.json ${MAIN_BACKUP_DIR}/visiology-realm.json
  m2m_secret=$(docker exec -it "${keycloak_container_id}" cat /run/secrets/KEYCLOAK_M2M_SECRET)
  grafana_client_secret=$(docker exec -it "${keycloak_container_id}" cat /run/secrets/KEYCLOAK_GRAFANA_CLIENT_SECRET)
  public_dashboard_access_secret=$(docker exec -it "${keycloak_container_id}" cat /run/secrets/KEYCLOAK_PUBLIC_DASHBOARD_ACCESS_SECRET)
  visiology_admin_realm_secret=$(docker exec -it "${keycloak_container_id}" cat /run/secrets/KEYCLOAK_VISIOLOGY_ADMIN_REALM_SECRET)
  m2m_secret_new="68c96230-43e8-4308-b0ae-65835d8de35e"
  grafana_client_secret_new="749e9d46-1360-4c65-a0a0-82ba3e369b09"
  public_dashboard_access_secret_new="49d410ba-4e0d-4b1a-a064-834f41fb1cfd"
  visiology_admin_realm_secret_new="23e5da38-76e9-47d2-e12c-f0da9f039cc6"
  sed -i "s/${m2m_secret}/${m2m_secret_new}/g" ${MAIN_BACKUP_DIR}/visiology-realm.json
  sed -i "s/${grafana_client_secret}/${grafana_client_secret_new}/g" ${MAIN_BACKUP_DIR}/visiology-realm.json
  sed -i "s/${public_dashboard_access_secret}/${public_dashboard_access_secret_new}/g" ${MAIN_BACKUP_DIR}/visiology-realm.json
  sed -i "s/${visiology_admin_realm_secret}/${visiology_admin_realm_secret_new}/g" ${MAIN_BACKUP_DIR}/visiology-realm.json
fi

# Backup Minio
if [ "${WITH_MINIO}" = ${TRUE} ]; then
  mkdir -p ${MN_FILES_HOST_PATH}
  minio_container_id=$(docker ps | grep "${PROJECT}_minio" | awk '{ print $1 }')
  if docker exec "${minio_container_id}" test -d "${MN_FILES_CONTAINER_PATH}/dev"; then
    docker cp "${minio_container_id}":${MN_FILES_CONTAINER_PATH}/dev ${MN_FILES_HOST_PATH}
  fi
  if docker exec "${minio_container_id}" test -d "${MN_FILES_CONTAINER_PATH}/permanent"; then
    docker cp "${minio_container_id}":${MN_FILES_CONTAINER_PATH}/permanent ${MN_FILES_HOST_PATH}
  fi
fi

# Backup DATA_MANAGEMENT_SECRET_KEY
if [ "${WITH_DM_SECRET_KEY}" = ${TRUE} ]; then
  mkdir -p ${SECRETS_FILES_HOST_PATH}
  dms_container_id=$(docker ps | grep "${PROJECT}_data-management-service" | awk '{ print $1 }')
  docker exec -i ${dms_container_id} sh -c 'cat /run/secrets/DATA_MANAGEMENT_SECRET_KEY; echo -n ""' >> ${SECRETS_FILES_HOST_PATH}/dm-secret.txt
fi

# Backup AI_API_KEY
if [ "${WITH_AI_SECRET_KEY}" = ${TRUE} ]; then
  mkdir -p ${SECRETS_FILES_HOST_PATH}
  ai_agent_container_id=$(docker ps | grep "${PROJECT}_ai-agent" | awk '{ print $1 }')
  docker exec -i ${ai_agent_container_id} sh -c 'cat /run/secrets/AI_API_KEY; echo -n ""' >> ${SECRETS_FILES_HOST_PATH}/ai-secret.txt
fi

# Backup mail settings
if [ "${WITH_MAIL}" = ${TRUE} ]; then
  mkdir -p ${SECRETS_FILES_HOST_PATH}
  ds_container_id=$(docker ps | grep "${PROJECT}_dashboard-service" |  awk '{ print $1 }')
  docker exec -i ${ds_container_id} sh -c 'cat /run/secrets/DS_EMAIL_LOGIN; echo -n ""' >> ${SECRETS_FILES_HOST_PATH}/ds-email-login-secret.txt
  docker exec -i ${ds_container_id} sh -c 'cat /run/secrets/DS_EMAIL_PASSWORD; echo -n ""' >> ${SECRETS_FILES_HOST_PATH}/ds-email-password-secret.txt
fi

# Backup ONEC_CONNECTOR_FERNET
if [ "${WITH_ONEC}" = ${TRUE} ]; then
  mkdir -p ${SECRETS_FILES_HOST_PATH}
  onec_container_id=$(docker ps | grep "${PROJECT}_onec-connector.1" | awk '{ print $1 }')
  docker exec -i ${onec_container_id} sh -c 'cat /run/secrets/ONEC_CONNECTOR_FERNET; echo -n ""' >> ${SECRETS_FILES_HOST_PATH}/onec-secret.txt
fi

# Tar
archive_name="$(hostname)-backup-v${VERSION}-$(date '+%Y-%m-%d-%H-%M-%S').tar.gz"
backup_file_dir=$(dirname $(readlink -f ${BACKUP_DIR}/${archive_name}))
tar -zcvf ${backup_file_dir}/${archive_name} -C ${backup_file_dir} backup

echo "Backup completed successfully!"
echo "Archive: ${backup_file_dir}/${archive_name}"
user1@srv-stand:/$ ^C
user1@srv-stand:/$ cat /var/lib/visiology/scripts/v3/restore.sh
#!/bin/bash -e

# Version 3.16.1
error_output=/dev/null

if [[ -v VI_DEBUG ]]; then
  set -x
  error_output=/dev/fd/1
fi

SCRIPT_DIR=$( dirname -- "$( readlink -f -- "$0")")
pushd "${SCRIPT_DIR}"

# Exit codes:
EXIT_OK=0
EXIT_NO_ARCHIVE_NAME=1
EXIT_NO_ARCHIVE_FILE=2
WRONG_ARGUMENTS_COUNT=15
INVALID_ARGUMENT=20
UNKNOWN_KEY=127

# Defines
TRUE="true"
FALSE="false"
UNDEFINED=255
RED='\033[0;31m'
NC='\033[0m'
source config.env

MAIN_BACKUP_DIR="${BACKUP_DIR%/}/backup"
DV_CUSTOM_SCRIPTS_HOST_PATH="${MAIN_BACKUP_DIR}/dashboard-viewer/customjs"
DV_CUSTOM_SCRIPTS_CONTAINER_PATH="${PERSISTENT_STORAGE_FOLDER}/dashboard-viewer"
MN_FILES_HOST_PATH="${MAIN_BACKUP_DIR}/minio"
MN_FILES_CONTAINER_PATH="/data"
SECRETS_FILES_HOST_PATH="${MAIN_BACKUP_DIR}/secrets"
EXTENDED_SERVICES_PATH="extended-services"
ENV_FILES_PATH="env-files"
CUSTOM_CONFIGS_PATH="custom-configs"
#PROJECT="visiology3" in config.env

# Variables
withPostgresFlag=${UNDEFINED}
withClickhouseFlag=${UNDEFINED}
withSFFlag=${UNDEFINED}
withKeycloakFlag=${UNDEFINED}
withMinioFlag=${UNDEFINED}
withDmSecretKeyFlag=${UNDEFINED}
withAiSecretKeyFlag=${UNDEFINED}
withMailFlag=${UNDEFINED}
withCustomFlag=${UNDEFINED}
withOnecFlag=${UNDEFINED}
archiveName=${UNDEFINED}

WITH_POSTGRES=${TRUE}
WITH_CLICKHOUSE=${TRUE}
WITH_SF=${TRUE}
WITH_KEYCLOAK=${FALSE}
WITH_MINIO=${TRUE}
WITH_DM_SECRET_KEY=${TRUE}
WITH_AI_SECRET_KEY=${FALSE}
WITH_MAIL=${FALSE}
WITH_CUSTOM=${TRUE}
WITH_ONEC=${FALSE}

databases_str=""

### Functions
print_help() {
  echo
  echo "Usage: $0 [OPTIONS]"
  echo "   -? | -h | --help                     Display this help message."
  echo "   -d | --debug                         Optional. Launches in debug mode."
  echo "   -a | --archive-name                  Archive name .tar.gz"
  echo "   --with-postgres <${TRUE}|${FALSE}>         Restore backup with Postgres data. Default: ${TRUE}"
  echo "   --with-clickhouse <${TRUE}|${FALSE}>       Restore backup with ClickHouse data. Default: ${TRUE}"
  echo "   --with-sf <${TRUE}|${FALSE}>               Restore backup with Smart Forms. Default: ${TRUE}"
  echo "   --with-keycloak <${TRUE}|${FALSE}>         Restore backup with KeyCloak data. Default: ${FALSE}"
  echo "   --with-minio <${TRUE}|${FALSE}>            Restore backup with Minio data (xlsx/csv/images files). Default: ${TRUE}"
  echo "   --with-dm-secret-key <${TRUE}|${FALSE}>    Restore backup with DATA_MANAGEMENT_SECRET_KEY. Default: ${TRUE}"
  echo "   --with-ai-secret-key <${TRUE}|${FALSE}>    Restore backup with AI_API_KEY. Default: ${FALSE}"
  echo "   --with-mail <${TRUE}|${FALSE}>             Restore backup with mail settings. Default: ${FALSE}"
  echo "   --with-custom-settings <${TRUE}|${FALSE}>  Restore backup with services custom settings. Default: ${TRUE}"
  echo "   --with-onec <${TRUE}|${FALSE}>             Restore backup with onec data. Default: ${FALSE}"
  echo
}

check_input_arguments() {
  # Arguments:
  #  1) variable for checking
  #  2) parameter name
  if [ $# != 2 ]; then
    echo "Function 'check_input_arguments' has wrong arguments count: need 2, has $#. Arguments: $*" >&2
    exit "${WRONG_ARGUMENTS_COUNT}"
  fi

  if [ "$1" != "${TRUE}" ] && [ "$1" != "${FALSE}" ]; then
    echo "Invalid value '$1' of argument '$2'. See help: $0 -h" >&2
    exit "${INVALID_ARGUMENT}"
  fi

  echo "$1"
}


###

# Parse command line arguments
while [ "$1" != "" ]; do
  case "$1" in
    "-?" | "-h" | "--help")
      print_help
      exit ${EXIT_OK}
    ;;
    "-d" | "--debug")
      set -x
    ;;
    "-a" | "--archive-name")
      shift
      archiveName="$1"
      ;;
    "--with-postgres")
     shift
      withPostgresFlag="$1"
      ;;
    "--with-clickhouse")
      shift
      withClickhouseFlag="$1"
      ;;
    "--with-keycloak")
      shift
      withKeycloakFlag="$1"
      ;;
    "--with-minio")
      shift
      withMinioFlag="$1"
      ;;
    "--with-dm-secret-key")
      shift
      withDmSecretKeyFlag="$1"
      ;;
    "--with-ai-secret-key")
      shift
      withAiSecretKeyFlag="$1"
      ;;
    "--with-mail")
      shift
      withMailFlag="$1"
      ;;
    "--with-sf")
      shift
      withSFFlag="$1"
      ;;
    "--with-custom-settings")
      shift
      withCustomFlag="$1"
      ;;
    "--with-onec")
      shift
      withOnecFlag="$1"
      ;;
    *)
      echo "Unknown key: $1"
      print_help
      exit ${UNKNOWN_KEY}
      ;;
  esac
  shift
done
###

### Archive name checking argument
if [ "${archiveName}" == "${UNDEFINED}" ]; then
  echo "No archive name!"
  exit ${EXIT_NO_ARCHIVE_NAME}
fi

### Backup databases checking arguments
if [ "${withPostgresFlag}" != "${UNDEFINED}" ]; then
  WITH_POSTGRES=$(check_input_arguments "${withPostgresFlag}" '--with-postgres')
fi

if [ "${withClickhouseFlag}" != "${UNDEFINED}" ]; then
  WITH_CLICKHOUSE=$(check_input_arguments "${withClickhouseFlag}" '--with-clickhouse')
fi

if [ "${withKeycloakFlag}" != "${UNDEFINED}" ]; then
  WITH_KEYCLOAK=$(check_input_arguments "${withKeycloakFlag}" '--with-keycloak')
fi

if [ "${withMinioFlag}" != "${UNDEFINED}" ]; then
  WITH_MINIO=$(check_input_arguments "${withMinioFlag}" '--with-minio')
fi

if [ "${withDmSecretKeyFlag}" != "${UNDEFINED}" ]; then
  WITH_DM_SECRET_KEY=$(check_input_arguments "${withDmSecretKeyFlag}" '--with-dm-secret-key')
fi

if [ "${withAiSecretKeyFlag}" != "${UNDEFINED}" ]; then
  WITH_AI_SECRET_KEY=$(check_input_arguments "${withAiSecretKeyFlag}" '--with-ai-secret-key')
fi

if [ "${withMailFlag}" != "${UNDEFINED}" ]; then
  WITH_MAIL=$(check_input_arguments "${withMailFlag}" '--with-mail')
fi

if [ "${withSFFlag}" != "${UNDEFINED}" ]; then
  WITH_SF=$(check_input_arguments "${withSFFlag}" '--with-sf')
fi

if [ "${withCustomFlag}" != "${UNDEFINED}" ]; then
  WITH_CUSTOM=$(check_input_arguments "${withCustomFlag}" '--with-custom-settings')
fi

if [ "${withOnecFlag}" != "${UNDEFINED}" ]; then
  WITH_ONEC=$(check_input_arguments "${withOnecFlag}" '--with-onec')
fi
###

### Databases str
if [ "${WITH_POSTGRES}" = ${TRUE} ]; then
  databases_str='"postgres"'
fi

if [ "${WITH_CLICKHOUSE}" = ${TRUE} ]; then
  databases_str=${databases_str}${databases_str:+,}' "clickhouse"'
fi

if [ "${WITH_SF}" = ${TRUE} ]; then
  databases_str=${databases_str}${databases_str:+,}' "smartforms"'
fi

if [ "${WITH_ONEC}" = ${TRUE} ]; then
  databases_str=${databases_str}${databases_str:+,}' "onec"'
fi

databases_str='['${databases_str}']'
###

# Checking the existence of an archive
if [ ! -f "${archiveName}" ]; then
  echo "File ${archiveName} not found!"
  exit ${EXIT_NO_ARCHIVE_FILE}
fi

# Clearing the backup directory
rm -rf ${MAIN_BACKUP_DIR}/*

### Clean up custom scripts dir
rm -rf ${DV_CUSTOM_SCRIPTS_CONTAINER_PATH}/*

# Unpacking
echo "Unpacking ${archiveName}..."
backup_dir_name=$(dirname ${BACKUP_DIR})
tar -xvf "${archiveName}" -C ${BACKUP_DIR}
chmod -R ug+X ${MAIN_BACKUP_DIR}

# Restore Databases
container_id=$(docker ps | grep "${PROJECT}_backup-service" |  awk '{ print $1 }')
docker exec "${container_id}" curl -sLv --request POST --url http://127.0.0.1:8000 --header 'Content-Type: application/json' --data '{"command":"restore","databases":'"${databases_str}"'}'

# Restore custom scripts
cp -ra ${DV_CUSTOM_SCRIPTS_HOST_PATH} "${DV_CUSTOM_SCRIPTS_CONTAINER_PATH}"

# Restore KeyCloak
if [ "${WITH_KEYCLOAK}" = ${TRUE} ]; then
  keycloak_realm=$(sed -n '/"realm" *: *"/{s/.*"realm" *: *"\([^"]*\)".*/\1/p;q;}' ${MAIN_BACKUP_DIR}/visiology-realm.json)
  keycloak_container_id=$(docker ps | grep "${PROJECT}_keycloak" |  awk '{ print $1 }')
  m2m_secret=$(docker exec -it "${keycloak_container_id}" cat /run/secrets/KEYCLOAK_M2M_SECRET)
  grafana_client_secret=$(docker exec -it "${keycloak_container_id}" cat /run/secrets/KEYCLOAK_GRAFANA_CLIENT_SECRET)
  public_dashboard_access_secret=$(docker exec -it "${keycloak_container_id}" cat /run/secrets/KEYCLOAK_PUBLIC_DASHBOARD_ACCESS_SECRET)
  visiology_admin_realm_secret=$(docker exec -it "${keycloak_container_id}" cat /run/secrets/KEYCLOAK_VISIOLOGY_ADMIN_REALM_SECRET)
  m2m_secret_old="68c96230-43e8-4308-b0ae-65835d8de35e"
  grafana_client_secret_old="749e9d46-1360-4c65-a0a0-82ba3e369b09"
  public_dashboard_access_secret_old="49d410ba-4e0d-4b1a-a064-834f41fb1cfd"
  visiology_admin_realm_secret_old="23e5da38-76e9-47d2-e12c-f0da9f039cc6"
  sed -i "s/${m2m_secret_old}/${m2m_secret}/g" ${MAIN_BACKUP_DIR}/visiology-realm.json
  sed -i "s/${grafana_client_secret_old}/${grafana_client_secret}/g" ${MAIN_BACKUP_DIR}/visiology-realm.json
  sed -i "s/${public_dashboard_access_secret_old}/${public_dashboard_access_secret}/g" ${MAIN_BACKUP_DIR}/visiology-realm.json
  sed -i "s/${visiology_admin_realm_secret_old}/${visiology_admin_realm_secret}/g" ${MAIN_BACKUP_DIR}/visiology-realm.json
  docker cp ${MAIN_BACKUP_DIR}/visiology-realm.json "${keycloak_container_id}":/opt/keycloak/visiology-realm.json
  docker exec -it "${keycloak_container_id}" bash -c \
    "global_admin_login=\$(cat /run/secrets/KEYCLOAK_ADMIN);\
    global_admin_password=\$(cat /run/secrets/KEYCLOAK_ADMIN_PASSWORD);\
    /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080/v3/keycloak --realm master --user \${global_admin_login} --password \${global_admin_password};\
    /opt/keycloak/bin/kcadm.sh delete -x realms/${keycloak_realm} &> ${error_output} || true"
  docker exec -it "${keycloak_container_id}" /opt/keycloak/bin/kc.sh import --file /opt/keycloak/visiology-realm.json > ${error_output} || true
  docker exec -it "${keycloak_container_id}" /opt/keycloak/bin/change-url.sh
fi
###

# Restore Minio
if [ "${WITH_MINIO}" = ${TRUE} ]; then
  minio_container_id=$(docker ps | grep "${PROJECT}_minio" | awk '{ print $1 }')
  docker cp ${MN_FILES_HOST_PATH}/. "${minio_container_id}":${MN_FILES_CONTAINER_PATH}
fi

# Restore DATA_MANAGEMENT_SECRET_KEY
if [ "${WITH_DM_SECRET_KEY}" = ${TRUE} ]; then
  docker service scale ${PROJECT}_data-management-service=0
  docker service update --secret-rm DATA_MANAGEMENT_SECRET_KEY ${PROJECT}_data-management-service
  docker secret rm DATA_MANAGEMENT_SECRET_KEY
  docker secret create -l ${PROJECT}_data_namagement=data_namagement_secret_key DATA_MANAGEMENT_SECRET_KEY ${SECRETS_FILES_HOST_PATH}/dm-secret.txt
  docker service update --secret-add source=DATA_MANAGEMENT_SECRET_KEY,target=DATA_MANAGEMENT_SECRET_KEY ${PROJECT}_data-management-service
  docker service scale ${PROJECT}_data-management-service=1
fi

# Restore AI_API_KEY
if [ "${WITH_AI_SECRET_KEY}" = ${TRUE} ]; then
  docker service scale ${PROJECT}_ai-agent=0
  docker service update --secret-rm AI_API_KEY ${PROJECT}_ai-agent
  docker secret rm AI_API_KEY
  docker secret create -l ${PROJECT}_ai_agent=ai_api_key AI_API_KEY ${SECRETS_FILES_HOST_PATH}/ai-secret.txt
  docker service update --secret-add source=AI_API_KEY,target=AI_API_KEY ${PROJECT}_ai-agent
  docker service scale ${PROJECT}_ai-agent=1
fi

docker service update --init visiology3_formula-engine

# Restore ONEC_CONNECTOR_FERNET
if [ "${WITH_ONEC}" = ${TRUE} ]; then
  docker service scale ${PROJECT}_onec-connector=0
  docker service update --secret-rm ONEC_CONNECTOR_FERNET ${PROJECT}_onec-connector
  docker secret rm ONEC_CONNECTOR_FERNET
  docker secret create -l ${PROJECT}_onec_connector=onec_connector_fernet ONEC_CONNECTOR_FERNET ${SECRETS_FILES_HOST_PATH}/onec-secret.txt
  docker service update --secret-add source=ONEC_CONNECTOR_FERNET,target=ONEC_CONNECTOR_FERNET ${PROJECT}_onec-connector
  docker service scale ${PROJECT}_onec-connector=1
fi

# Restore mail setting
if [ "${WITH_MAIL}" = ${TRUE} ]; then
  docker service scale ${PROJECT}_dashboard-service=0
  docker service scale ${PROJECT}_data-management-service=0
  docker service update --secret-rm DS_EMAIL_LOGIN ${PROJECT}_dashboard-service
  docker service update --secret-rm DS_EMAIL_PASSWORD ${PROJECT}_dashboard-service
  docker service update --secret-rm DS_EMAIL_LOGIN ${PROJECT}_data-management-service
  docker service update --secret-rm DS_EMAIL_PASSWORD ${PROJECT}_data-management-service
  docker secret rm DS_EMAIL_LOGIN
  docker secret rm DS_EMAIL_PASSWORD
  docker secret create -l ${PROJECT}_ds_email=login DS_EMAIL_LOGIN ${SECRETS_FILES_HOST_PATH}/ds-email-login-secret.txt
  docker secret create -l ${PROJECT}_ds_email=password DS_EMAIL_PASSWORD ${SECRETS_FILES_HOST_PATH}/ds-email-password-secret.txt
  docker service update --secret-add source=DS_EMAIL_LOGIN,target=DS_EMAIL_LOGIN ${PROJECT}_dashboard-service
  docker service update --secret-add source=DS_EMAIL_PASSWORD,target=DS_EMAIL_PASSWORD ${PROJECT}_dashboard-service
  docker service update --secret-add source=DS_EMAIL_LOGIN,target=DS_EMAIL_LOGIN ${PROJECT}_data-management-service
  docker service update --secret-add source=DS_EMAIL_PASSWORD,target=DS_EMAIL_PASSWORD ${PROJECT}_data-management-service
  docker service scale ${PROJECT}_dashboard-service=1
  docker service scale ${PROJECT}_data-management-service=1

  echo -e "${RED}Для применения новых настроек почтового сервера перезапустите платформу:\n/var/lib/visiology/scripts/run.sh --restart${NC}"
fi

# Restore custom settings
if [ "${WITH_CUSTOM}" = ${TRUE} ]; then
  ### Clean up env files dir
  rm -rf ${ENV_FILES_PATH}/*
  ### Clean up extended services dir
  rm -rf ${EXTENDED_SERVICES_PATH}/*
  ### Clean up custom configs dir
  rm -rf ${CUSTOM_CONFIGS_PATH}/*
  # Restore custom configs
  cp -ra ${MAIN_BACKUP_DIR}/${EXTENDED_SERVICES_PATH} .
  # Restore extended services
  cp -ra ${MAIN_BACKUP_DIR}/${ENV_FILES_PATH} .
  # Restore env files
  cp -ra ${MAIN_BACKUP_DIR}/${CUSTOM_CONFIGS_PATH} .

  echo -e "${RED}Для применения новых кастомных настроек остановите платформу:\n/var/lib/visiology/scripts/run.sh --stop${NC}"
  echo -e "${RED}Запустите обновление конфигураций:\n/var/lib/visiology/scripts/v3/prepare-config.sh --force-regenerate-configs${NC}"
  echo -e "${RED}Перезапустите платформу:\n/var/lib/visiology/scripts/run.sh --restart${NC}"
fi

echo "Restore completed successfully!"
