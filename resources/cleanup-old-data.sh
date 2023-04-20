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

cleanup_old_data