#!/bin/sh

# Set the has_failed variable to false. This will change if any of the subsequent database backups/uploads fail.
has_failed=false

cleanup_old_data() {
    if [ -n "${DB_CLEANUP_TIME}" ]; then
        if [ "${has_failed}" != true ]; then
        
            AWS_CONNECT="--host=${AWS_S3_ENDPOINT} --host-bucket=${AWS_BUCKET_NAME}.${AWS_S3_ENDPOINT} --access_key=${AWS_ACCESS_KEY_ID} --secret_key=${AWS_SECRET_ACCESS_KEY}"
           
            echo -e "Cleaning up old backups on S3 storage"
            s3cmd ${AWS_CONNECT} ls s3://${AWS_BUCKET_NAME}/${AWS_BUCKET_BACKUP_PATH}/ | grep " DIR " -v | grep " PRE " -v | while read -r s3_file; do
                s3_createdate=$(echo $s3_file | awk {'print $1" "$2'})
                s3_createdate=$(date -d "$s3_createdate" "+%s")
                s3_olderthan=$(echo $(( $(date +%s)-${DB_CLEANUP_TIME}*60 )))
                if [ $s3_createdate -le $s3_olderthan ] ; then
                    s3_filename=$(echo $s3_file | awk {'print $4'})
                    if [ "$s3_filename" != "" ] ; then
                        echo -e "Deleting $s3_filename"
                         s3cmd ${AWS_CONNECT} rm ${s3_filename}
                    fi
                fi
            done
            
        else
            echo -e "Skipping Cleaning up old backups because there were errors in backing up"
        fi
    fi
}

# Set the BACKUP_CREATE_DATABASE_STATEMENT variable
if [ "$BACKUP_CREATE_DATABASE_STATEMENT" = "true" ]; then
    BACKUP_CREATE_DATABASE_STATEMENT="--databases"
else
    BACKUP_CREATE_DATABASE_STATEMENT=""
fi

if [ "$TARGET_ALL_DATABASES" = "true" ]; then
    # Ignore any databases specified by TARGET_DATABASE_NAMES
    if [ ! -z "$TARGET_DATABASE_NAMES" ]
    then
        echo "Both TARGET_ALL_DATABASES is set to 'true' and databases are manually specified by 'TARGET_DATABASE_NAMES'. Ignoring 'TARGET_DATABASE_NAMES'..."
        TARGET_DATABASE_NAMES=""
    fi
    # Build Database List
    ALL_DATABASES_EXCLUSION_LIST="'mysql','sys','tmp','information_schema','performance_schema','test'"
    ALL_DATABASES_SQLSTMT="SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN (${ALL_DATABASES_EXCLUSION_LIST})"
    if ! ALL_DATABASES_DATABASE_LIST=`mysql -u $TARGET_DATABASE_USER -h $TARGET_DATABASE_HOST -p$TARGET_DATABASE_PASSWORD -P $TARGET_DATABASE_PORT -ANe"${ALL_DATABASES_SQLSTMT}"`
    then
        echo -e "Building list of all databases failed at $(date +'%d-%m-%Y %H:%M:%S')." | tee -a /tmp/kubernetes-cloud-mysql-backup.log
        has_failed=true
    fi
    if [ "$has_failed" = false ]; then
        for DB in ${ALL_DATABASES_DATABASE_LIST}
        do
            TARGET_DATABASE_NAMES="${TARGET_DATABASE_NAMES}${DB},"
        done
        #Remove trailing comma
        TARGET_DATABASE_NAMES=${TARGET_DATABASE_NAMES%?}
        echo -e "Successfully built list of all databases (${TARGET_DATABASE_NAMES}) at $(date +'%d-%m-%Y %H:%M:%S')."
    fi
fi

# Loop through all the defined databases, seperating by a ,
if [ "$has_failed" = false ]; then
    for CURRENT_DATABASE in ${TARGET_DATABASE_NAMES//,/ }; do

        if [ -n "$BACKUP_COMPRESS" ]; then
            DUMP=$CURRENT_DATABASE.sql
            DUMP_TS=$CURRENT_DATABASE$(date +$BACKUP_TIMESTAMP).sql
        else
            DUMP=$CURRENT_DATABASE$(date +$BACKUP_TIMESTAMP).sql
        fi

        # Perform the database backup. Put the output to a variable. If successful upload the backup to S3, if unsuccessful print an entry to the console and the log, and set has_failed to true.
        if sqloutput=$(mysqldump -u $TARGET_DATABASE_USER -h $TARGET_DATABASE_HOST -p$TARGET_DATABASE_PASSWORD -P $TARGET_DATABASE_PORT $BACKUP_ADDITIONAL_PARAMS $BACKUP_CREATE_DATABASE_STATEMENT $CURRENT_DATABASE  2>&1 > /tmp/$DUMP); then

            echo -e "Database backup successfully completed for $CURRENT_DATABASE at $(date +'%d-%m-%Y %H:%M:%S')."

            # Optionally compress the backup
            if [ -n "$BACKUP_COMPRESS" ]; then
                zstd -q -9 /tmp/${DUMP} -o /tmp/${DUMP_TS}.zst
                echo -e "Compressed backup with zstd"
                rm /tmp/${DUMP}
                DUMP="$DUMP_TS".zst
            fi

            # Optionally encrypt the backup
            if [ -n "$AGE_PUBLIC_KEY" ]; then
                cat /tmp/"$DUMP" | age -a -r "$AGE_PUBLIC_KEY" >/tmp/"$DUMP".age
                echo -e "Encrypted backup with age"
                rm /tmp/"$DUMP"
                DUMP="$DUMP".age
            fi

            # Convert BACKUP_PROVIDER to lowercase before executing if statement
            BACKUP_PROVIDER=$(echo "$BACKUP_PROVIDER" | awk '{print tolower($0)}')

            # If the Backup Provider is AWS, then upload to S3
            if [ "$BACKUP_PROVIDER" = "aws" ]; then

                # If the AWS_S3_ENDPOINT variable isn't empty, then populate the --endpoint-url parameter to use a custom S3 compatable endpoint
                if [ ! -z "$AWS_S3_ENDPOINT" ]; then
                    AWS_CONNECT="--host=${AWS_S3_ENDPOINT} --host-bucket=${AWS_BUCKET_NAME}.${AWS_S3_ENDPOINT} --access_key=${AWS_ACCESS_KEY_ID} --secret_key=${AWS_SECRET_ACCESS_KEY}"
                fi

                # Perform the upload to S3. Put the output to a variable. If successful, print an entry to the console and the log. If unsuccessful, set has_failed to true and print an entry to the console and the log
                if awsoutput=$(s3cmd $AWS_CONNECT put /tmp/$DUMP s3://$AWS_BUCKET_NAME/$AWS_BUCKET_BACKUP_PATH/$DUMP 2>&1); then
                    echo -e "Database backup successfully uploaded for $CURRENT_DATABASE at $(date +'%d-%m-%Y %H:%M:%S')."
                else
                    echo -e "Database backup failed to upload for $CURRENT_DATABASE at $(date +'%d-%m-%Y %H:%M:%S'). Error: $awsoutput" | tee -a /tmp/kubernetes-cloud-mysql-backup.log
                    has_failed=true
                fi
                rm /tmp/"$DUMP"
            fi

        else
            echo -e "Database backup FAILED for $CURRENT_DATABASE at $(date +'%d-%m-%Y %H:%M:%S'). Error: $sqloutput" | tee -a /tmp/kubernetes-cloud-mysql-backup.log
            has_failed=true
        fi

    done
fi

# Check if any of the backups have failed. If so, exit with a status of 1. Otherwise exit cleanly with a status of 0.
if [ "$has_failed" = true ]; then
    echo -e "kubernetes-cloud-mysql-backup encountered 1 or more errors. Exiting with status code 1."
    exit 1

else
    echo -e "All database backups successfully completed on database host $TARGET_DATABASE_HOST."
    cleanup_old_data
    exit 0
fi
