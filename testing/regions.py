from base import TestKeystoneBase
import requests

class TestKeystoneRegions(TestKeystoneBase):
    def setUp(self):
        super(TestKeystoneRegions, self).setUp()
        self.host = self.host + '/v3/regions/'

    def create(self):
        body = {
            "region": {
                "description": "My subregion",
                "id": "RegionOne",
            }
        }
        self.res = requests.post(self.host, json = body)
        self.checkCode(201)

    def list(self):
        self.res = requests.get(self.host)
        self.checkCode(200)

    def get_info(self):
        self.res = requests.get(self.host + '/RegionOneSubRegion')
        self.checkCode(200)

    def update(self):
        body = {
            "region": {
                "description": "My subregion 3"
            }
        }
        self.res = requests.patch(self.host + '/RegionOneSubRegion', json=body)
        self.checkCode(200)

    def delete(self):
        self.res = requests.delete(self.host + '/RegionOneSubRegion1')
        self.checkCode(204)
