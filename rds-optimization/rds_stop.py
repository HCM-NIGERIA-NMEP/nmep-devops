import boto3
import time

rds = boto3.client('rds')

def lambda_handler(event, context):

    #Stop DB instances
    dbs = rds.describe_db_instances()
    for db in dbs['DBInstances']:
        #Check if DB instance is not already stopped
        if (db['DBInstanceStatus'] == 'available'):
            try:
                GetTags=rds.list_tags_for_resource(ResourceName=db['DBInstanceArn'])['TagList']
                for tags in GetTags:
                #if tag "autostop=yes" is set for instance, stop it
                    if(tags['Key'] == 'AutoStop' and tags['Value'] == 'true'):
                        if db['DBInstanceClass'] != 'db.t3.micro':
                            print(f"Modifying instance type of {db['DBInstanceIdentifier']} to db.t3.micro...")
                            rds.modify_db_instance(
                                DBInstanceIdentifier=db['DBInstanceIdentifier'],
                                DBInstanceClass='db.t3.micro',
                                ApplyImmediately=True
                            )
                            time.sleep(30)
                            # Wait until modification is finished and DB is available again
                            waiter = rds.get_waiter('db_instance_available')
                            print(f"Waiting for {db['DBInstanceIdentifier']} to become available after modification...")
                            waiter.wait(DBInstanceIdentifier=db['DBInstanceIdentifier'])
                            print(f"Instance {db['DBInstanceIdentifier']} is now available with db.t3.micro")
                        result = rds.stop_db_instance(DBInstanceIdentifier=db['DBInstanceIdentifier'])
                        print ("Stopping instance: {0}.".format(db['DBInstanceIdentifier']))
            except Exception as e:
                print ("Cannot stop instance {0}.".format(db['DBInstanceIdentifier']))
                print(e)
                
if __name__ == "__main__":
    lambda_handler(None, None)