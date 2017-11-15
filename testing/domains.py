from base import TestKeystoneBase
import requests

class TestKeystoneDomains(TestKeystoneBase):
    def setUp(self):
        super(TestKeystoneDomains, self).setUp()
        self.host = self.host + '/v3/domains/'
    def create(self):
        body = {
            "domain" : {
                "name": "default_domain",
                "description" : "kuku",
                "enabled" :  True
            }
        }
        res = requests.post(self.host, json = body)
        self.checkCode(res, 201)

        response = res.json()
        for k, v in response.items():
            print(k, '\n\t', v)

    def delete(self):
        domain_id = '85220b62-f5cf-4fc7-adce-823e320592f4'
        res = requests.delete(self.host + domain_id)
        self.checkCode(res, 204)

    def update (self):
        domain_id = '85220b62-f5cf-4fc7-adce-823e320592f4'
        body = {
        "domain": {
            "description": "My updated domain",
            "name": "myUpdatedDomain"
            }
        }
        res = requests.patch(self.host + domain_id, json=body)
        self.checkCode(res, 200)

        response = res.json()
        for k, v in response.items():
            print(k, '\n\t', v)

    def list(self):
        res = requests.get(self.host)
        self.checkCode(res, 200)

        response = res.json()
        for k, v in response.items():
            print(k, '\n\t', v)
