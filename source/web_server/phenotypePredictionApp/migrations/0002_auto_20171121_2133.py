# -*- coding: utf-8 -*-
# Generated by Django 1.11.7 on 2017-11-21 20:33
from __future__ import unicode_literals

from django.db import migrations, models
import django.utils.timezone
import uuid


class Migration(migrations.Migration):

    dependencies = [
        ('phenotypePredictionApp', '0001_initial'),
    ]

    operations = [
        migrations.AddField(
            model_name='resultfile',
            name='actualID',
            field=models.TextField(default=django.utils.timezone.now),
            preserve_default=False,
        ),
        migrations.AlterField(
            model_name='job',
            name='job_name',
            field=models.TextField(default=uuid.UUID('aa655722-6475-40d6-872b-2a8ec26eb884'), primary_key=True, serialize=False),
        ),
        migrations.AlterField(
            model_name='resultfile',
            name='document',
            field=models.FileField(upload_to='resultFiles/<django.db.models.fields.TextField>tar.gz'),
        ),
        migrations.AlterField(
            model_name='uploadedfile',
            name='key',
            field=models.TextField(default=uuid.UUID('f1722ee9-fe79-4f10-a8aa-aed9e979f303')),
        ),
    ]